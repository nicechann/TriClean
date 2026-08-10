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
    
    // MARK: - 스캔 작업 핸들
    
    /// 스캔 Task를 보관해 사용자가 중간에 중지할 수 있게 한다.
    /// (기존에는 Task.isCancelled 검사만 있고 핸들을 버려서 취소가 불가능했다.)
    private var scanTask: Task<Void, Never>? = nil
    /// 뒤늦게 끝난 이전 스캔이 새 스캔의 상태를 덮어쓰지 않도록 하는 세대 번호.
    private var scanGeneration: UInt = 0
    
    // MARK: - Bookmark 관리
    
    private let bookmarks = SecurityScopedBookmarkStore.shared
    
    init() {
        loadBookmark()
    }
    
    private func loadBookmark() {
        // 1) Junk 전용 북마크 시도 — 유효한 Library 경로인 경우에만 사용
        if let url = bookmarks.resolveURL(for: .junkLibraryFolder), isLibraryLike(url) {
            libraryURL = url
            return
        }
        
        // 2) Apps 탭에서 이미 ~/Library를 선택한 적이 있으면 재사용
        if let url = bookmarks.resolveURL(for: .appsUserLibraryFolder), isLibraryLike(url) {
            libraryURL = url
            bookmarks.trySave(url: url, for: .junkLibraryFolder)
            return
        }
        
        // 3) 둘 다 없거나 유효하지 않으면 nil — UI에서 자동 안내
    }
    
    /// ~/Library 경로인지 빠르게 확인 (파일 시스템 접근 없이)
    private func isLibraryLike(_ url: URL) -> Bool {
        let path = url.path
        return path.hasSuffix("/Library") || path.hasSuffix("/Library/")
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
            bookmarks.trySave(url: url, for: .junkLibraryFolder)
            libraryURL = url
            accessDenied = false
            cleanupNotice = nil
        }
    }
    
    // MARK: - 스캔
    
    func scan() {
        guard let library = libraryURL else { return }
        guard !isScanning else { return }
        
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        
        isScanning = true
        accessDenied = false
        cleanupNotice = nil
        results = []
        scanProgress = "junk.progress.preparing".localized
        
        let categories = JunkCategory.defaultCategories
        let libraryStd = library.standardizedFileURL
        
        scanTask = Task {
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
                    guard generation == self.scanGeneration else { return }
                    self.scanTask = nil
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
                    guard generation == self.scanGeneration else { return }
                    self.scanProgress = "junk.progress.scanning_format".localized(with: category.name)
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
                    let worker = Task.detached(priority: .utility) {
                        Self.scanJunkItems(
                            at: targetURL,
                            categoryID: categoryID,
                            excludedChildNames: excludedChildNames,
                            defaultSelected: defaultSelected
                        )
                    }
                    let items = await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: {
                        // detached 작업은 부모 Task 취소를 자동 상속하지 않으므로 직접 전달한다.
                        worker.cancel()
                    }

                    guard !Task.isCancelled else { break }
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
            
            let wasCancelled = Task.isCancelled
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.scanTask = nil
                self.isScanning = false

                guard !wasCancelled else {
                    self.scanProgress = "storage.msg.canceled".localized
                    return
                }

                self.results = scanResults
                self.lastScanDate = Date()
                self.scanProgress = ""
            }
        }
    }

    /// 진행 중인 스캔을 중지한다.
    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        isScanning = false
        scanProgress = "storage.msg.canceled".localized
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
        guard !Task.isCancelled else { return [] }
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
            guard !Task.isCancelled else { break }
            guard !excludedChildNames.contains(itemURL.lastPathComponent) else {
                continue
            }

            let itemSize = folderSize(at: itemURL)
            guard !Task.isCancelled else { break }
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
        guard !Task.isCancelled else { return 0 }
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
            guard !Task.isCancelled else {
                enumerator.skipDescendants()
                break
            }
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

    private struct CleanOutcome: Sendable {
        let succeededIDs: Set<UUID>
        let failedCount: Int
        let excludedCount: Int
        let accessDenied: Bool
        let firstFailure: TrashService.Failure?
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
        if let url = bookmarks.resolveURL(for: .junkLibraryFolder), isLibraryLike(url) {
            libraryURL = url
            return url
        }

        if let url = bookmarks.resolveURL(for: .appsUserLibraryFolder), isLibraryLike(url) {
            bookmarks.trySave(url: url, for: .junkLibraryFolder)
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

    nonisolated private static func moveTargetsToTrash(
        _ candidates: [CleanTarget],
        securityScopedBy securityScopedURL: URL,
        validationScope: URL
    ) async -> CleanOutcome {
        let started = securityScopedURL.startAccessingSecurityScopedResource()
        guard started else {
            Logger(subsystem: "com.nicechann.TriClean", category: "JunkCleanup").error(
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

        // 권한이 활성화된 상태에서 경로 경계·존재 여부·항목 정체성을 삭제 직전에 검사합니다.
        let outcome = await TrashService.sanitizeAndMoveToTrash(
            candidates,
            scopes: [.descendants(of: validationScope)],
            url: \.url,
            identity: \.fileIdentity,
            allowsDirectoryContentChanges: {
                $0.identityValidationPolicy == .allowDirectoryContentChanges
            },
            logCategory: "JunkCleanup"
        )

        return CleanOutcome(
            succeededIDs: Set(outcome.succeeded.map(\.id)),
            failedCount: outcome.failedCount,
            excludedCount: outcome.excludedCount,
            accessDenied: false,
            firstFailure: outcome.firstFailure
        )
    }

}
