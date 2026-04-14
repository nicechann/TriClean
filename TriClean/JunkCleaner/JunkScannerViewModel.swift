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
    
    // MARK: - Bookmark 관리
    
    private let bookmarkKey = "TriClean.JunkCleaner.LibraryBookmark"
    
    init() {
        loadBookmark()
    }
    
    private func loadBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            libraryURL = url
            if stale { saveBookmark(url: url) }
        }
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
        let panel = NSOpenPanel()
        panel.title = "Select ~/Library Folder"
        panel.message = "정크 파일 스캔을 위해 Home Library 폴더를 선택하세요."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        
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
        scanProgress = "스캔 준비 중..."
        
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
                    scanProgress = "\(category.name) 스캔 중..."
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
        let started = library.startAccessingSecurityScopedResource()
        defer { if started { library.stopAccessingSecurityScopedResource() } }
        
        var cleaned: Int64 = 0
        let fm = FileManager.default
        
        for item in targets {
            do {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
                cleaned += item.sizeBytes
            } catch {
                // Fallback: NSWorkspace
                NSWorkspace.shared.recycle([item.url]) { _, _ in }
            }
        }
        
        // 삭제된 항목 제거
        let deletedIDs = Set(targets.map(\.id))
        for i in 0..<results.count {
            results[i].items.removeAll { deletedIDs.contains($0.id) }
        }
        results.removeAll { $0.items.isEmpty }
    }
}
