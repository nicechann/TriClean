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
        }
    }
    
    // MARK: - 스캔
    
    func scan() {
        guard let library = libraryURL else { return }
        guard !isScanning else { return }
        
        isScanning = true
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
                    let items = await Task.detached(priority: .utility) {
                        Self.scanJunkItems(
                            at: targetURL,
                            categoryID: category.id
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
    
    nonisolated private static func scanJunkItems(
        at url: URL,
        categoryID: String
    ) -> [JunkItem] {
        let fm = FileManager.default
        
        // 단일 파일인 경우
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        
        if !isDir.boolValue {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            guard size > 0 else { return [] }
            return [JunkItem(url: url, sizeBytes: size, categoryID: categoryID)]
        }
        
        // 폴더인 경우 — 하위 아이템별로 크기 계산
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey],
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
                categoryID: categoryID
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
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
            ) else { continue }
            
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        
        return total
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
    
    func cleanSelected() {
        let targets = results.flatMap { $0.items.filter(\.isSelected) }
        guard !targets.isEmpty else { return }
        guard let library = libraryURL else { return }
        
        // ✅ [수정] 비동기 fallback(NSWorkspace.recycle)의 결과까지 정확히 반영해
        //   "실패한 항목이 UI에서 사라지는" 버그를 막습니다.
        Task {
            let started = library.startAccessingSecurityScopedResource()
            defer { if started { library.stopAccessingSecurityScopedResource() } }
            
            let fm = FileManager.default
            var succeededIDs = Set<UUID>()
            var failedCount = 0
            
            for item in targets {
                do {
                    try fm.trashItem(at: item.url, resultingItemURL: nil)
                    succeededIDs.insert(item.id)
                } catch {
                    // Fallback: NSWorkspace.recycle (비동기 콜백 → CheckedContinuation으로 동기화)
                    let ok: Bool = await withCheckedContinuation { continuation in
                        NSWorkspace.shared.recycle([item.url]) { _, error in
                            continuation.resume(returning: error == nil)
                        }
                    }
                    if ok {
                        succeededIDs.insert(item.id)
                    } else {
                        failedCount += 1
                    }
                }
            }
            
            // ✅ 성공한 항목만 UI에서 제거 (실패한 항목은 유지하여 사용자가 재시도 가능)
            for i in 0..<results.count {
                results[i].items.removeAll { succeededIDs.contains($0.id) }
            }
            results.removeAll { $0.items.isEmpty }
            
            // 실패가 있어도 결과 목록에 남아있어 사용자가 자연스럽게 인지/재시도 가능.
            // (별도 상태 메시지 없이 UI 상태로만 표시)
            _ = failedCount
        }
    }
}
