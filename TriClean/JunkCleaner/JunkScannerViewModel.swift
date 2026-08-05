//
//  JunkScannerViewModel.swift
//  TriClean
//
//  ~/Library 하위의 알려진 정크 경로를 자동 스캔하는 ViewModel
//
//  전제조건:
//  - 사용자가 ~/Library 폴더에 대한 Security-Scoped Bookmark을 제공해야 함
//  - 기존 AppsView의 userLibraryFolder 선택 UI를 공유하거나,
//    별도로 ~/Library 접근 권한을 요청
//

import Foundation
import Combine
import SwiftUI
import AppKit
import os.log


private let junkCleanupLogger = Logger(
    subsystem: "com.nicechann.TriClean",
    category: "JunkCleanup"
)

struct JunkCleanupNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case success
        case warning
        case error
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
}

@MainActor
final class JunkScannerViewModel: ObservableObject {
    
    // MARK: - Published State
    
    @Published var results: [JunkScanResult] = []
    @Published var isScanning: Bool = false
    @Published var scanProgress: String = ""
    @Published var libraryURL: URL? = nil
    @Published var lastScanDate: Date? = nil
    @Published var isCleaning: Bool = false
    @Published var cleanupNotice: JunkCleanupNotice? = nil
    /// 스캔 시 폴더 접근 권한이 만료/무효인 경우 true. (조용한 빈 결과 방지용)
    @Published var accessDenied: Bool = false
    
    // MARK: - Computed
    
    var totalJunkBytes: Int64 {
        results.reduce(0) { $0 + $1.totalBytes }
    }
    
    var selectedJunkBytes: Int64 {
        results.reduce(0) { $0 + $1.selectedBytes }
    }
    
    var totalJunkString: String {
        ByteCountFormatter.string(fromByteCount: totalJunkBytes, countStyle: .file)
    }
    
    var selectedJunkString: String {
        ByteCountFormatter.string(fromByteCount: selectedJunkBytes, countStyle: .file)
    }
    
    var hasResults: Bool { !results.isEmpty }
    
    /// 선택된 경로가 ~/Library처럼 보이는지 확인
    var isValidLibraryPath: Bool {
        guard let url = libraryURL else { return false }
        let path = url.path
        if path.hasSuffix("/Library") || path.hasSuffix("/Library/") { return true }
        let fm = FileManager.default
        let knownSubs = ["Caches", "Logs", "Preferences", "Application Support"]
        for sub in knownSubs {
            if fm.fileExists(atPath: url.appendingPathComponent(sub).path) { return true }
        }
        return false
    }
    
    // MARK: - Bookmark 관리
    
    private let bookmarkKey = "TriClean.JunkCleaner.LibraryBookmark"
    /// Apps 탭에서 이미 ~/Library 권한을 받았을 수 있음 — 해당 북마크 키
    private let appsLibraryBookmarkKey = "TriClean.Apps.Bookmark.UserLibraryFolder"
    
    init() {
        loadBookmark()
    }
    
    private func loadBookmark() {
        // 1) Junk 전용 북마크 시도 — 유효한 Library 경로인 경우에만 사용
        if let url = resolveBookmark(forKey: bookmarkKey), isLibraryLike(url) {
            libraryURL = url
            return
        }
        
        // 2) Apps 탭에서 이미 ~/Library를 선택한 적이 있으면 재사용
        if let url = resolveBookmark(forKey: appsLibraryBookmarkKey), isLibraryLike(url) {
            libraryURL = url
            saveBookmark(url: url)
            return
        }
        
        // 3) 둘 다 없거나 유효하지 않으면 nil — UI에서 자동 안내
    }
    
    /// ~/Library 경로인지 빠르게 확인 (파일 시스템 접근 없이)
    private func isLibraryLike(_ url: URL) -> Bool {
        let path = url.path
        return path.hasSuffix("/Library") || path.hasSuffix("/Library/")
    }
    
    private func resolveBookmark(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale { saveBookmark(url: url) }
        return url
    }
    
    private func saveBookmark(url: URL) {
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }
    
    // MARK: - 폴더 선택
    
    func selectLibraryFolder() {
        let homeLibrary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        
        let panel = NSOpenPanel()
        panel.title = "junk.scope.title".localized
        panel.message = "junk.scope.message".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = homeLibrary
        // ~/Library를 기본 선택 상태로 (사용자가 Open만 누르면 됨)
        panel.nameFieldStringValue = "Library"
        
        if panel.runModal() == .OK, let url = panel.url {
            saveBookmark(url: url)
            libraryURL = url
            accessDenied = false
            cleanupNotice = nil
        }
    }
    
    // MARK: - 스캔
    
    func scan() {
        guard let library = libraryURL else { return }
        guard !isScanning else { return }
        
        isScanning = true
        accessDenied = false
        cleanupNotice = nil
        results = []
        scanProgress = "junk.progress.preparing".localized
        
        let categories = JunkCategory.defaultCategories
        let libraryStd = library.standardizedFileURL
        
        Task {
            // Security-Scoped 접근은 북마크에서 복원한 원본 URL로 시작하고,
            // standardized URL은 경로 계산과 검증에만 사용합니다.
            let started = library.startAccessingSecurityScopedResource()
            defer {
                if started { library.stopAccessingSecurityScopedResource() }
            }
            
            // ✅ 접근 권한 검증: 스코프 접근 실패 + 디렉터리 읽기 불가면
            //    조용히 빈 결과로 끝내지 않고 재선택을 안내한다.
            let readable = await Task.detached(priority: .utility) {
                Self.isDirectoryReadable(libraryStd)
            }.value
            // ✅ [수정] 기존 `!started && !readable`은 스코프는 열렸지만 북마크가
            //    stale해서 실제로 읽을 수 없는 경우를 통과시켜, 조용히 빈 결과를
            //    보여줬다. 읽기 가능 여부만으로 판정한다.
            if !readable {
                await MainActor.run {
                    self.isScanning = false
                    self.accessDenied = true
                    self.scanProgress = ""
                }
                return
            }

            var scanResults: [JunkScanResult] = []
            
            for category in categories {
                if Task.isCancelled { break }
                
                await MainActor.run {
                    scanProgress = "junk.progress.scanning_format".localized(with: category.name)
                }
                
                var categoryItems: [JunkItem] = []
                
                for relativePath in category.relativePaths {
                    let targetURL = libraryStd.appendingPathComponent(relativePath)
                    
                    guard FileManager.default.fileExists(atPath: targetURL.path) else {
                        continue
                    }
                    
                    // 폴더 전체 크기 계산
                    let categoryID = category.id
                    let defaultSelected = category.riskLevel.defaultSelected
                    let excludedChildNames = category.excludedChildNames
                    let items = await Task.detached(priority: .utility) {
                        Self.scanJunkItems(
                            at: targetURL,
                            categoryID: categoryID,
                            excludedChildNames: excludedChildNames,
                            defaultSelected: defaultSelected
                        )
                    }.value
                    
                    categoryItems.append(contentsOf: items)
                }
                
                if !categoryItems.isEmpty {
                    scanResults.append(JunkScanResult(
                        id: category.id,
                        category: category,
                        items: categoryItems.sorted { $0.sizeBytes > $1.sizeBytes }
                    ))
                }
            }
            
            // 결과를 크기순으로 정렬
            scanResults.sort { $0.totalBytes > $1.totalBytes }
            
            await MainActor.run {
                self.results = scanResults
                self.isScanning = false
                self.lastScanDate = Date()
                self.scanProgress = ""
            }
        }
    }
    
    // MARK: - 정크 아이템 스캔 (백그라운드)
    
    /// 디렉터리 읽기 가능 여부 프로브(권한 실패 시 false).
    nonisolated private static func isDirectoryReadable(_ url: URL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func scanJunkItems(
        at url: URL,
        categoryID: String,
        excludedChildNames: Set<String>,
        defaultSelected: Bool
    ) -> [JunkItem] {
        let fm = FileManager.default
        
        // 단일 파일인 경우
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        
        if !isDir.boolValue {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            guard size > 0 else { return [] }
            return [JunkItem(url: url, sizeBytes: size, categoryID: categoryID, isSelected: defaultSelected)]
        }
        
        // 폴더인 경우 — 하위 아이템별로 크기 계산
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        var items: [JunkItem] = []
        items.reserveCapacity(contents.count)
        
        for itemURL in contents {
            guard !excludedChildNames.contains(itemURL.lastPathComponent) else {
                continue
            }

            let itemSize = folderSize(at: itemURL)
            guard itemSize > 1024 else { continue } // 1KB 미만 스킵
            
            items.append(JunkItem(
                url: itemURL,
                sizeBytes: itemSize,
                categoryID: categoryID,
                isSelected: defaultSelected
            ))
        }
        
        return items
    }
    
    /// 폴더 전체 크기 (재귀)
    nonisolated private static func folderSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
            ) else { continue }
            
            if values.isRegularFile == true {
                total += Int64(Self.fileSize(from: values))
            }
        }
        
        return total
    }
    
    nonisolated private static func fileSize(from values: URLResourceValues) -> Int {
        values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
    }

    // MARK: - 선택 토글
    
    func toggleItem(in categoryID: String, itemID: UUID) {
        guard let catIdx = results.firstIndex(where: { $0.id == categoryID }),
              let itemIdx = results[catIdx].items.firstIndex(where: { $0.id == itemID })
        else { return }
        
        results[catIdx].items[itemIdx].isSelected.toggle()
    }
    
    func toggleAll(in categoryID: String) {
        guard let index = results.firstIndex(where: { $0.id == categoryID }) else { return }
        results[index].toggleAllSelection()
    }

    func selectAll(in categoryID: String) {
        guard let index = results.firstIndex(where: { $0.id == categoryID }) else { return }
        results[index].setAllSelected(true)
    }
    
    func deselectAll(in categoryID: String) {
        guard let index = results.firstIndex(where: { $0.id == categoryID }) else { return }
        results[index].setAllSelected(false)
    }
    
    // MARK: - 삭제

    private struct CleanTarget: Sendable {
        let id: UUID
        let url: URL
        let fileIdentity: FileIdentitySnapshot?
        let identityValidationPolicy: JunkCategory.IdentityValidationPolicy
    }

    private struct CleanFailure: Sendable {
        let path: String
        let domain: String
        let code: Int
        let message: String

        init(url: URL, error: Error) {
            let nsError = error as NSError
            self.path = url.path
            self.domain = nsError.domain
            self.code = nsError.code
            self.message = nsError.localizedDescription
        }
    }

    private struct CleanOutcome: Sendable {
        let succeededIDs: Set<UUID>
        let failedCount: Int
        let excludedCount: Int
        let accessDenied: Bool
        let firstFailure: CleanFailure?
    }

    func cleanSelected() {
        startCleaning(categoryID: nil)
    }

    func cleanSelected(in categoryID: String) {
        startCleaning(categoryID: categoryID)
    }

    func dismissCleanupNotice() {
        cleanupNotice = nil
    }

    nonisolated static func selectedItems(
        in results: [JunkScanResult],
        categoryID: String? = nil
    ) -> [JunkItem] {
        let scopedResults: [JunkScanResult]
        if let categoryID {
            scopedResults = results.filter { $0.id == categoryID }
        } else {
            scopedResults = results
        }

        return scopedResults.flatMap { $0.items.filter(\.isSelected) }
    }

    /// 삭제 직전에는 저장된 북마크에서 security-scoped URL을 다시 복원합니다.
    /// `standardizedFileURL`은 경로 검증에만 사용하고, 권한 활성화에는 복원 원본을 사용합니다.
    private func resolveLibraryURLForCleaning() -> URL? {
        if let url = resolveBookmark(forKey: bookmarkKey), isLibraryLike(url) {
            libraryURL = url
            return url
        }

        if let url = resolveBookmark(forKey: appsLibraryBookmarkKey), isLibraryLike(url) {
            saveBookmark(url: url)
            libraryURL = url
            return url
        }

        return nil
    }

    private func startCleaning(categoryID: String?) {
        guard StoreManager.shared.isPurchased else {
            scanProgress = "paywall.free_mode.notice".localized
            return
        }
        guard !isCleaning else { return }

        let scopedResults: [JunkScanResult]
        if let categoryID {
            scopedResults = results.filter { $0.id == categoryID }
        } else {
            scopedResults = results
        }

        let candidates = scopedResults.flatMap { result in
            result.items.filter(\.isSelected).map { item in
                CleanTarget(
                    id: item.id,
                    url: item.url.standardizedFileURL,
                    fileIdentity: item.fileIdentity,
                    identityValidationPolicy: result.category.identityValidationPolicy
                )
            }
        }
        guard !candidates.isEmpty else { return }

        cleanupNotice = nil

        guard let securityScopedLibrary = resolveLibraryURLForCleaning() else {
            accessDenied = true
            cleanupNotice = JunkCleanupNotice(
                kind: .error,
                title: "common.permission_needed".localized,
                message: "junk.cleanup.result.access_denied".localized
            )
            return
        }

        let validationScope = securityScopedLibrary.standardizedFileURL
        isCleaning = true
        scanProgress = "junk.progress.cleaning".localized(with: candidates.count)

        Task {
            let outcome = await Task.detached(priority: .utility) {
                await Self.moveTargetsToTrash(
                    candidates,
                    securityScopedBy: securityScopedLibrary,
                    validationScope: validationScope
                )
            }.value

            for index in results.indices {
                results[index].items.removeAll { outcome.succeededIDs.contains($0.id) }
            }
            results.removeAll { $0.items.isEmpty }

            isCleaning = false
            publishCleanupOutcome(outcome, requestedCount: candidates.count)
        }
    }

    private func publishCleanupOutcome(_ outcome: CleanOutcome, requestedCount: Int) {
        if outcome.accessDenied {
            accessDenied = true
            scanProgress = ""
            cleanupNotice = JunkCleanupNotice(
                kind: .error,
                title: "common.permission_needed".localized,
                message: "junk.cleanup.result.access_denied".localized
            )
            return
        }

        accessDenied = false
        let succeeded = outcome.succeededIDs.count
        let baseMessage: String
        let kind: JunkCleanupNotice.Kind
        let title: String

        if succeeded == requestedCount && outcome.failedCount == 0 && outcome.excludedCount == 0 {
            kind = .success
            title = "junk.cleanup.result.success_title".localized
            baseMessage = "junk.cleanup.result.success_message".localized(with: succeeded)
            scanProgress = "junk.progress.clean_done".localized(with: succeeded)
        } else if succeeded > 0 {
            kind = .warning
            title = "junk.cleanup.result.partial_title".localized
            baseMessage = "junk.cleanup.result.partial_message".localized(
                with: succeeded,
                outcome.failedCount,
                outcome.excludedCount
            )
            scanProgress = "junk.progress.clean_summary".localized(
                with: succeeded,
                outcome.failedCount,
                outcome.excludedCount
            )
        } else {
            kind = .error
            title = "junk.cleanup.result.failed_title".localized
            baseMessage = "junk.cleanup.result.failed_message".localized(
                with: outcome.failedCount,
                outcome.excludedCount
            )
            scanProgress = outcome.excludedCount > 0
                ? "junk.progress.clean_invalid".localized(with: outcome.excludedCount)
                : "junk.progress.clean_failed".localized
        }

        let message: String
        if let failure = outcome.firstFailure {
            message = baseMessage + "\n"
                + "junk.cleanup.result.error_detail".localized(with: failure.message)
        } else {
            message = baseMessage
        }

        cleanupNotice = JunkCleanupNotice(kind: kind, title: title, message: message)
    }

    nonisolated private static func isIdentityCurrent(_ target: CleanTarget) -> Bool {
        guard let snapshot = target.fileIdentity else { return false }
        let allowDirectoryContentChanges =
            target.identityValidationPolicy == .allowDirectoryContentChanges
        return snapshot.matchesCurrentItem(
            at: target.url,
            allowDirectoryContentChanges: allowDirectoryContentChanges
        )
    }

    nonisolated private static func revalidateTargets(
        _ candidates: [CleanTarget]
    ) -> (accepted: [CleanTarget], rejectedCount: Int) {
        var accepted: [CleanTarget] = []
        var rejectedCount = 0

        for target in candidates {
            if isIdentityCurrent(target) {
                accepted.append(target)
            } else {
                rejectedCount += 1
            }
        }

        return (accepted, rejectedCount)
    }

    nonisolated private static func moveTargetsToTrash(
        _ candidates: [CleanTarget],
        securityScopedBy securityScopedURL: URL,
        validationScope: URL
    ) async -> CleanOutcome {
        let started = securityScopedURL.startAccessingSecurityScopedResource()
        guard started else {
            junkCleanupLogger.error(
                "Security-scoped access failed for \(securityScopedURL.path, privacy: .public)"
            )
            return CleanOutcome(
                succeededIDs: [],
                failedCount: candidates.count,
                excludedCount: 0,
                accessDenied: true,
                firstFailure: nil
            )
        }
        defer { securityScopedURL.stopAccessingSecurityScopedResource() }

        // 권한이 활성화된 상태에서 경로 경계와 존재 여부를 삭제 직전에 검사합니다.
        let sanitized = DeletionSafety.sanitize(
            candidates,
            scope: validationScope,
            url: \.url
        )
        let identityValidated = revalidateTargets(sanitized.accepted)
        let fm = FileManager.default
        var succeededIDs = Set<UUID>()
        var failedCount = 0
        var runtimeRejectedCount = 0
        var firstFailure: CleanFailure?

        for target in identityValidated.accepted {
            // 앞선 항목을 처리하는 동안 실행 중인 앱이 같은 경로를 다시 만들 수 있으므로
            // 실제 휴지통 이동 직전에 항목 정체성을 한 번 더 확인합니다.
            guard isIdentityCurrent(target) else {
                runtimeRejectedCount += 1
                continue
            }

            do {
                try fm.trashItem(at: target.url, resultingItemURL: nil)
                succeededIDs.insert(target.id)
            } catch {
                let fileManagerFailure = CleanFailure(url: target.url, error: error)
                junkCleanupLogger.warning(
                    "FileManager trash failed path=\(fileManagerFailure.path, privacy: .public) domain=\(fileManagerFailure.domain, privacy: .public) code=\(fileManagerFailure.code) message=\(fileManagerFailure.message, privacy: .public)"
                )

                // trashItem 실패 후 NSWorkspace 폴백을 실행하기 직전에도 다시 검증합니다.
                guard isIdentityCurrent(target) else {
                    runtimeRejectedCount += 1
                    continue
                }

                if let workspaceFailure = await recycleUsingWorkspace(target.url) {
                    junkCleanupLogger.error(
                        "NSWorkspace recycle failed path=\(workspaceFailure.path, privacy: .public) domain=\(workspaceFailure.domain, privacy: .public) code=\(workspaceFailure.code) message=\(workspaceFailure.message, privacy: .public)"
                    )
                    failedCount += 1
                    if firstFailure == nil {
                        firstFailure = workspaceFailure
                    }
                } else {
                    succeededIDs.insert(target.id)
                }
            }
        }

        return CleanOutcome(
            succeededIDs: succeededIDs,
            failedCount: failedCount,
            excludedCount: sanitized.rejectedCount
                + identityValidated.rejectedCount
                + runtimeRejectedCount,
            accessDenied: false,
            firstFailure: firstFailure
        )
    }

    /// 성공 시 nil, 실패 시 사용자 표시와 로그에 사용할 오류 정보를 반환합니다.
    @MainActor
    private static func recycleUsingWorkspace(_ url: URL) async -> CleanFailure? {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error {
                    continuation.resume(returning: CleanFailure(url: url, error: error))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

}
