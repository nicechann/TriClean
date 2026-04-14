//
//  DuplicateScannerViewModel.swift
//  TriClean
//
//  중복 파일 탐색 ViewModel
//  3단계 필터링: 파일 크기 → 부분 해시(4KB) → 전체 해시
//
//  샌드박스 제약:
//  - 사용자가 NSOpenPanel으로 선택한 폴더만 접근 가능
//  - Security-Scoped Bookmark으로 권한 유지
//

import Foundation
import Combine
import SwiftUI
import AppKit
import CryptoKit

@MainActor
final class DuplicateScannerViewModel: ObservableObject {
    
    // MARK: - Published
    
    @Published var groups: [DuplicateGroup] = []
    @Published var isScanning: Bool = false
    @Published var phase: DuplicateScanPhase = .idle
    @Published var progress: Double = 0       // 0.0 ~ 1.0
    @Published var statusMessage: String = ""
    @Published var scanFolderURL: URL? = nil
    @Published var minFileSizeKB: Int = 100    // 최소 파일 크기 (KB)
    
    // MARK: - Computed
    
    var totalDuplicateGroups: Int { groups.count }
    
    var totalReclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }
    
    var totalReclaimableString: String {
        ByteCountFormatter.string(fromByteCount: totalReclaimableBytes, countStyle: .file)
    }
    
    var totalFilesScanned: Int { scannedFileCount }
    private var scannedFileCount: Int = 0
    
    // MARK: - Bookmark
    
    private let bookmarkKey = "TriClean.DuplicateFinder.FolderBookmark"
    
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
            scanFolderURL = url
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
    
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "duplicates.panel.title".localized
        panel.message = "duplicates.panel.message".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        
        if panel.runModal() == .OK, let url = panel.url {
            saveBookmark(url: url)
            scanFolderURL = url
        }
    }
    
    // MARK: - 스캔
    
    func scan() {
        guard let folderURL = scanFolderURL else { return }
        guard !isScanning else { return }
        
        isScanning = true
        groups = []
        progress = 0
        scannedFileCount = 0
        
        let minBytes = Int64(minFileSizeKB) * 1024
        let rootURL = folderURL.standardizedFileURL
        
        Task {
            let started = rootURL.startAccessingSecurityScopedResource()
            defer { if started { rootURL.stopAccessingSecurityScopedResource() } }
            
            // Phase 1: 파일 수집
            phase = .collectingFiles
            statusMessage = "duplicates.status.collecting".localized
            
            let allFiles = await Task.detached(priority: .utility) {
                Self.collectFiles(in: rootURL, minBytes: minBytes)
            }.value
            
            scannedFileCount = allFiles.count
            statusMessage = "duplicates.status.files_found".localized(with: allFiles.count)
            
            guard !allFiles.isEmpty else {
                finishScan()
                return
            }
            
            // Phase 2: 크기별 그룹화
            phase = .groupingBySize
            statusMessage = "duplicates.status.grouping".localized
            
            let sizeGroups = Dictionary(grouping: allFiles) { $0.size }
                .filter { $0.value.count >= 2 }  // 같은 크기가 2개 이상인 것만
            
            let candidates = sizeGroups.values.flatMap { $0 }
            statusMessage = "duplicates.status.size_candidates".localized(with: candidates.count)
            
            guard !candidates.isEmpty else {
                finishScan()
                return
            }
            
            // Phase 3: 부분 해시 (처음 4KB)
            phase = .hashingPartial
            let partialGroups = await Task.detached(priority: .utility) {
                Self.groupByPartialHash(files: candidates, sizeGroups: sizeGroups)
            }.value
            
            let partialCandidates = partialGroups.values.filter { $0.count >= 2 }
            statusMessage = "duplicates.status.partial_matches".localized(with: partialCandidates.count)
            
            guard !partialCandidates.isEmpty else {
                finishScan()
                return
            }
            
            // Phase 4: 전체 해시
            phase = .hashingFull
            let totalToHash = partialCandidates.flatMap { $0 }.count
            var hashed = 0
            
            var finalGroups: [DuplicateGroup] = []
            
            for partialGroup in partialCandidates {
                if Task.isCancelled { break }
                
                var fullHashMap: [String: [FileCandidate]] = [:]
                
                for file in partialGroup {
                    let hash = await Task.detached(priority: .utility) {
                        Self.fullHash(of: file.url)
                    }.value
                    
                    guard let hash else { continue }
                    fullHashMap[hash, default: []].append(file)
                    
                    hashed += 1
                    await MainActor.run {
                        progress = Double(hashed) / Double(totalToHash)
                        statusMessage = "duplicates.status.full_progress".localized(with: hashed, totalToHash)
                    }
                }
                
                // 실제 중복 그룹 생성
                for (hash, files) in fullHashMap where files.count >= 2 {
                    var dupFiles = files.enumerated().map { idx, f in
                        DuplicateFile(
                            url: f.url,
                            modificationDate: f.modDate,
                            isKeep: idx == 0  // 첫 번째 파일을 기본 보존
                        )
                    }
                    // 가장 오래된 파일을 보존 대상으로
                    if let oldestIdx = dupFiles.indices.min(by: {
                        (dupFiles[$0].modificationDate ?? .distantFuture) <
                        (dupFiles[$1].modificationDate ?? .distantFuture)
                    }) {
                        for i in dupFiles.indices { dupFiles[i].isKeep = (i == oldestIdx) }
                    }
                    
                    finalGroups.append(DuplicateGroup(
                        hash: hash,
                        fileSize: files[0].size,
                        files: dupFiles
                    ))
                }
            }
            
            // 크기순 정렬
            finalGroups.sort { $0.reclaimableBytes > $1.reclaimableBytes }
            
            await MainActor.run {
                self.groups = finalGroups
            }
            
            finishScan()
        }
    }
    
    private func finishScan() {
        isScanning = false
        phase = .done
        progress = 1.0
        statusMessage = groups.isEmpty
            ? "duplicates.status.none_found".localized
            : "duplicates.status.found_groups".localized(with: groups.count, totalReclaimableString)
    }
    
    // MARK: - 보존/삭제 토글
    
    func toggleKeep(groupID: UUID, fileID: UUID) {
        guard let gIdx = groups.firstIndex(where: { $0.id == groupID }),
              let fIdx = groups[gIdx].files.firstIndex(where: { $0.id == fileID })
        else { return }
        
        groups[gIdx].files[fIdx].isKeep.toggle()
        
        // 최소 1개는 보존해야 함
        let keepCount = groups[gIdx].files.filter(\.isKeep).count
        if keepCount == 0 {
            groups[gIdx].files[fIdx].isKeep = true
        }
    }
    
    // MARK: - 삭제
    
    func deleteDuplicates() {
        guard let folder = scanFolderURL else { return }
        let started = folder.startAccessingSecurityScopedResource()
        defer { if started { folder.stopAccessingSecurityScopedResource() } }
        
        let fm = FileManager.default
        var deletedCount = 0
        
        for group in groups {
            for file in group.files where !file.isKeep {
                do {
                    try fm.trashItem(at: file.url, resultingItemURL: nil)
                    deletedCount += 1
                } catch {
                    NSWorkspace.shared.recycle([file.url]) { _, _ in }
                }
            }
        }
        
        // 삭제된 파일 제거 후 결과 갱신
        for i in 0..<groups.count {
            groups[i].files.removeAll { !$0.isKeep && !FileManager.default.fileExists(atPath: $0.url.path) }
        }
        groups.removeAll { $0.files.count <= 1 }
        
        statusMessage = "duplicates.status.deleted".localized(with: deletedCount)
    }
    
    // MARK: - 파일 수집 (백그라운드)
    
    private struct FileCandidate {
        let url: URL
        let size: Int64
        let modDate: Date?
    }
    
    nonisolated private static func collectFiles(in root: URL, minBytes: Int64) -> [FileCandidate] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .isDirectoryKey, .isPackageKey
        ]
        
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }
        
        var files: [FileCandidate] = []
        files.reserveCapacity(1000)
        
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }
            
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            guard size >= minBytes else { continue }
            
            files.append(FileCandidate(
                url: url,
                size: size,
                modDate: values.contentModificationDate
            ))
        }
        
        return files
    }
    
    // MARK: - 해시 (백그라운드)
    
    nonisolated private static func groupByPartialHash(
        files: [FileCandidate],
        sizeGroups: [Int64: [FileCandidate]]
    ) -> [String: [FileCandidate]] {
        var hashMap: [String: [FileCandidate]] = [:]
        
        for (_, group) in sizeGroups where group.count >= 2 {
            for file in group {
                guard let hash = partialHash(of: file.url) else { continue }
                let key = "\(file.size)_\(hash)"
                hashMap[key, default: []].append(file)
            }
        }
        
        return hashMap
    }
    
    /// 파일 처음 4KB의 SHA-256 해시
    nonisolated private static func partialHash(of url: URL, bytes: Int = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        
        let data = handle.readData(ofLength: bytes)
        guard !data.isEmpty else { return nil }
        
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// 파일 전체의 SHA-256 해시 (스트리밍)
    nonisolated private static func fullHash(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        
        var hasher = SHA256()
        let bufferSize = 64 * 1024  // 64KB chunks
        
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: bufferSize)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
