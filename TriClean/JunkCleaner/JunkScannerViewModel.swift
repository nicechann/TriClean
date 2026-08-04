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

@MainActor
final class JunkScannerViewModel: ObservableObject {
    
    // MARK: - Published State
    
    @Published var results: [JunkScanResult] = []
    @Published var isScanning: Bool = false
    @Published var scanProgress: String = ""
    @Published var libraryURL: URL? = nil
    @Published var lastScanDate: Date? = nil
    @Published var isCleaning: Bool = false
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
        }
    }
    
    // MARK: - 스캔
    
    func scan() {
        guard let library = libraryURL else { return }
        guard !isScanning else { return }
        
        isScanning = true
        accessDenied = false
        results = []
        scanProgress = "junk.progress.preparing".localized
        
        let categories = JunkCategory.defaultCategories
        let libraryStd = library.standardizedFileURL
        
        Task {
            // Security-Scoped 접근 시작
            let started = libraryStd.startAccessingSecurityScopedResource()
            defer {
                if started { libraryStd.stopAccessingSecurityScopedResource() }
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
                    let items = await Task.detached(priority: .utility) {
                        Self.scanJunkItems(
                            at: targetURL,
                            categoryID: categoryID,
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
    
    func selectAll(in categoryID: String) {
        guard let idx = results.firstIndex(where: { $0.id == categoryID }) else { return }
        for i in 0..<results[idx].items.count {
            results[idx].items[i].isSelected = true
        }
    }
    
    func deselectAll(in categoryID: String) {
        guard let idx = results.firstIndex(where: { $0.id == categoryID }) else { return }
        for i in 0..<results[idx].items.count {
            results[idx].items[i].isSelected = false
        }
    }
    
    // MARK: - 삭제
    
    private struct CleanTarget: Sendable {
        let id: UUID
        let url: URL
    }

    private struct CleanOutcome: Sendable {
        let succeededIDs: Set<UUID>
        let failedCount: Int
        let excludedCount: Int
    }

    func cleanSelected() {
        let candidates = results
            .flatMap { $0.items.filter(\.isSelected) }
            .map { CleanTarget(id: $0.id, url: $0.url.standardizedFileURL) }
        guard !candidates.isEmpty else { return }
        guard let library = libraryURL?.standardizedFileURL else { return }
        guard !isCleaning else { return }

        isCleaning = true
        scanProgress = "junk.progress.cleaning".localized(with: candidates.count)

        Task {
            let outcome = await Task.detached(priority: .utility) {
                await Self.moveTargetsToTrash(candidates, scopedBy: library)
            }.value

            for i in 0..<results.count {
                results[i].items.removeAll { outcome.succeededIDs.contains($0.id) }
            }
            results.removeAll { $0.items.isEmpty }

            isCleaning = false
            if outcome.succeededIDs.isEmpty {
                scanProgress = outcome.excludedCount > 0
                    ? "junk.progress.clean_invalid".localized(with: outcome.excludedCount)
                    : "junk.progress.clean_failed".localized
            } else if outcome.failedCount > 0 || outcome.excludedCount > 0 {
                scanProgress = "junk.progress.clean_summary".localized(
                    with: outcome.succeededIDs.count,
                    outcome.failedCount,
                    outcome.excludedCount
                )
            } else {
                scanProgress = "junk.progress.clean_done".localized(with: outcome.succeededIDs.count)
            }
        }
    }

    nonisolated private static func moveTargetsToTrash(
        _ candidates: [CleanTarget],
        scopedBy scopeURL: URL
    ) async -> CleanOutcome {
        let started = scopeURL.startAccessingSecurityScopedResource()
        defer { if started { scopeURL.stopAccessingSecurityScopedResource() } }

        // 보안 스코프가 열린 상태에서 경로 경계와 존재 여부를 삭제 직전에 검사합니다.
        let sanitized = DeletionSafety.sanitize(candidates, scope: scopeURL, url: \.url)
        let fm = FileManager.default
        var succeededIDs = Set<UUID>()
        var failedCount = 0

        for target in sanitized.accepted {
            do {
                try fm.trashItem(at: target.url, resultingItemURL: nil)
                succeededIDs.insert(target.id)
            } catch {
                let ok = await recycleUsingWorkspace(target.url)
                if ok {
                    succeededIDs.insert(target.id)
                } else {
                    failedCount += 1
                }
            }
        }

        return CleanOutcome(
            succeededIDs: succeededIDs,
            failedCount: failedCount,
            excludedCount: sanitized.rejectedCount
        )
    }

    @MainActor
    private static func recycleUsingWorkspace(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }
}
