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

struct DuplicateCleanupResult: Identifiable {
    let id = UUID()
    let deletedCount: Int
    let deletedBytes: Int64
    let failedCount: Int

    var deletedBytesString: String {
        ByteCountFormatter.string(fromByteCount: deletedBytes, countStyle: .file)
    }
}

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
    @Published var lastCleanupResult: DuplicateCleanupResult? = nil

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

    var selectedDeleteCount: Int {
        groups.reduce(0) { $0 + $1.selectedDeleteCount }
    }

    var selectedReclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.selectedDeleteBytes }
    }

    var selectedReclaimableString: String {
        ByteCountFormatter.string(fromByteCount: selectedReclaimableBytes, countStyle: .file)
    }

    var groupsWithSelectedDeletes: Int {
        groups.filter { $0.selectedDeleteCount > 0 }.count
    }

    var canDeleteSelected: Bool {
        selectedDeleteCount > 0
    }

    var selectedFolderPath: String {
        scanFolderURL?.path ?? ""
    }

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
        panel.title = "duplicate.select_folder.title".localized
        panel.message = "duplicate.select_folder.message".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        if panel.runModal() == .OK, let url = panel.url {
            saveBookmark(url: url)
            scanFolderURL = url
            lastCleanupResult = nil
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
        lastCleanupResult = nil

        let minBytes = Int64(minFileSizeKB) * 1024
        let rootURL = folderURL.standardizedFileURL

        Task {
            let started = rootURL.startAccessingSecurityScopedResource()
            defer { if started { rootURL.stopAccessingSecurityScopedResource() } }

            // Phase 1: 파일 수집
            phase = .collectingFiles
            statusMessage = "duplicate.status.collecting".localized

            let allFiles = await Task.detached(priority: .utility) {
                Self.collectFiles(in: rootURL, minBytes: minBytes)
            }.value

            scannedFileCount = allFiles.count
            statusMessage = "duplicate.status.found_files".localized(with: allFiles.count)

            guard !allFiles.isEmpty else {
                finishScan()
                return
            }

            // Phase 2: 크기별 그룹화
            phase = .groupingBySize
            statusMessage = "duplicate.status.grouping_by_size".localized

            let sizeGroups = Dictionary(grouping: allFiles) { $0.size }
                .filter { $0.value.count >= 2 }

            let candidates = sizeGroups.values.flatMap { $0 }
            statusMessage = "duplicate.status.same_size_candidates".localized(with: candidates.count)

            guard !candidates.isEmpty else {
                finishScan()
                return
            }

            // Phase 3: 부분 해시 (처음 4KB)
            phase = .hashingPartial
            let partialGroups = await Task.detached(priority: .utility) {
                Self.groupByPartialHash(sizeGroups: sizeGroups)
            }.value

            let partialCandidates = partialGroups.values.filter { $0.count >= 2 }
            statusMessage = "duplicate.status.partial_hash_matches".localized(with: partialCandidates.count)

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
                        progress = totalToHash > 0 ? Double(hashed) / Double(totalToHash) : 0
                        statusMessage = "duplicate.status.hashing_full_progress".localized(with: hashed, totalToHash)
                    }
                }

                // 실제 중복 그룹 생성
                for (hash, files) in fullHashMap where files.count >= 2 {
                    let dupFiles = Self.makeDuplicateFiles(from: files, rootURL: rootURL)

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
            ? "duplicate.status.no_duplicates_found".localized
            : "duplicate.status.scan_complete".localized(with: groups.count, selectedReclaimableString)
    }

    // MARK: - 보존/삭제 토글

    func toggleKeep(groupID: UUID, fileID: UUID) {
        guard let gIdx = groups.firstIndex(where: { $0.id == groupID }),
              let fIdx = groups[gIdx].files.firstIndex(where: { $0.id == fileID })
        else { return }

        groups[gIdx].files[fIdx].isKeep.toggle()

        // 최소 1개는 보존해야 함
        let keepCount = groups[gIdx].files.filter { $0.isKeep }.count
        if keepCount == 0 {
            groups[gIdx].files[fIdx].isKeep = true
        }

        updateSelectionStatusMessage()
    }

    func applyRecommendedSelection() {
        guard let rootURL = scanFolderURL?.standardizedFileURL else { return }

        for groupIndex in groups.indices {
            var files = groups[groupIndex].files
            let recommendedIndex = Self.recommendedKeepIndex(for: files, rootURL: rootURL)
            for fileIndex in files.indices {
                files[fileIndex].isKeep = (fileIndex == recommendedIndex)
            }
            groups[groupIndex].files = files
        }

        updateSelectionStatusMessage(fallback: "duplicate.status.recommended_applied".localized)
    }

    func keepNewest(in groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard let newestIndex = groups[groupIndex].files.indices.max(by: {
            (groups[groupIndex].files[$0].modificationDate ?? .distantPast) <
            (groups[groupIndex].files[$1].modificationDate ?? .distantPast)
        }) else { return }

        setKeepOnly(groupIndex: groupIndex, fileIndexToKeep: newestIndex)
        updateSelectionStatusMessage(fallback: "duplicate.status.keep_newest_applied".localized)
    }

    func keepOldest(in groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard let oldestIndex = groups[groupIndex].files.indices.min(by: {
            (groups[groupIndex].files[$0].modificationDate ?? .distantFuture) <
            (groups[groupIndex].files[$1].modificationDate ?? .distantFuture)
        }) else { return }

        setKeepOnly(groupIndex: groupIndex, fileIndexToKeep: oldestIndex)
        updateSelectionStatusMessage(fallback: "duplicate.status.keep_oldest_applied".localized)
    }

    private func setKeepOnly(groupIndex: Int, fileIndexToKeep: Int) {
        for fileIndex in groups[groupIndex].files.indices {
            groups[groupIndex].files[fileIndex].isKeep = (fileIndex == fileIndexToKeep)
        }
    }

    private func updateSelectionStatusMessage(fallback: String? = nil) {
        if canDeleteSelected {
            statusMessage = "duplicate.status.selection_summary".localized(
                with: groupsWithSelectedDeletes,
                selectedDeleteCount,
                selectedReclaimableString
            )
        } else if let fallback {
            statusMessage = fallback
        } else {
            statusMessage = "duplicate.status.nothing_selected".localized
        }
    }

    func clearDeleteSelection() {
        for groupIndex in groups.indices {
            for fileIndex in groups[groupIndex].files.indices {
                groups[groupIndex].files[fileIndex].isKeep = true
            }
        }

        updateSelectionStatusMessage(fallback: "duplicate.status.selection_cleared".localized)
    }

    // MARK: - Finder

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 삭제

    func deleteDuplicates() {
        guard let folder = scanFolderURL else { return }
        guard canDeleteSelected else {
            statusMessage = "duplicate.status.nothing_selected".localized
            return
        }

        let started = folder.startAccessingSecurityScopedResource()
        defer { if started { folder.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var deletedCount = 0
        var failedCount = 0
        var deletedBytes: Int64 = 0

        for group in groups {
            for file in group.files where !file.isKeep {
                do {
                    try fm.trashItem(at: file.url, resultingItemURL: nil)
                    deletedCount += 1
                    deletedBytes += group.fileSize
                } catch {
                    failedCount += 1
                }
            }
        }

        // 삭제된 파일 제거 후 결과 갱신
        for i in groups.indices {
            groups[i].files.removeAll { !$0.isKeep && !FileManager.default.fileExists(atPath: $0.url.path) }
        }
        groups.removeAll { $0.files.count <= 1 }

        lastCleanupResult = DuplicateCleanupResult(
            deletedCount: deletedCount,
            deletedBytes: deletedBytes,
            failedCount: failedCount
        )

        if deletedCount > 0 {
            statusMessage = failedCount > 0
                ? "duplicate.status.cleanup_done_with_failures".localized(with: deletedCount, ByteCountFormatter.string(fromByteCount: deletedBytes, countStyle: .file), failedCount)
                : "duplicate.status.cleanup_done".localized(with: deletedCount, ByteCountFormatter.string(fromByteCount: deletedBytes, countStyle: .file))
        } else {
            statusMessage = "duplicate.status.cleanup_failed".localized
        }
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

    private nonisolated static func makeDuplicateFiles(from files: [FileCandidate], rootURL: URL) -> [DuplicateFile] {
        var duplicateFiles = files.map { file in
            DuplicateFile(
                url: file.url,
                modificationDate: file.modDate,
                isKeep: false
            )
        }

        let keepIndex = recommendedKeepIndex(for: duplicateFiles, rootURL: rootURL)
        for index in duplicateFiles.indices {
            duplicateFiles[index].isKeep = (index == keepIndex)
        }
        return duplicateFiles
    }

    private nonisolated static func recommendedKeepIndex(for files: [DuplicateFile], rootURL: URL) -> Int {
        guard !files.isEmpty else { return 0 }

        var bestIndex = 0
        var bestScore = Int.min

        for (index, file) in files.enumerated() {
            let score = recommendationScore(for: file, rootURL: rootURL)
            if score > bestScore {
                bestScore = score
                bestIndex = index
            } else if score == bestScore {
                let currentFile = files[bestIndex]
                let lhsDate = file.modificationDate ?? .distantFuture
                let rhsDate = currentFile.modificationDate ?? .distantFuture
                if lhsDate < rhsDate {
                    bestIndex = index
                } else if lhsDate == rhsDate && file.url.path.count < currentFile.url.path.count {
                    bestIndex = index
                }
            }
        }

        return bestIndex
    }

    private nonisolated static func recommendationScore(for file: DuplicateFile, rootURL: URL) -> Int {
        let loweredName = file.url.lastPathComponent.lowercased()
        let duplicateMarkers = ["copy", "duplicate", "backup", "사본", "복사본", "백업"]

        var score = 0

        let relativePath = file.url.path.replacingOccurrences(of: rootURL.path, with: "")
        let depth = max(relativePath.split(separator: "/").count, 1)
        score += max(0, 60 - (depth * 6))

        if duplicateMarkers.contains(where: { loweredName.contains($0) }) {
            score -= 40
        }
        if loweredName.contains("(") || loweredName.contains(" copy") || loweredName.contains(" 2") {
            score -= 8
        }

        let parentPath = file.url.deletingLastPathComponent().path.lowercased()
        if parentPath.contains("downloads") || parentPath.contains("cache") || parentPath.contains("tmp") || parentPath.contains("trash") {
            score -= 18
        }
        if parentPath.contains("desktop") || parentPath.contains("documents") {
            score += 6
        }

        if let modificationDate = file.modificationDate {
            let ageInDays = Int(max(0, Date().timeIntervalSince(modificationDate) / 86_400))
            score += min(ageInDays, 30)
        }

        score -= min(file.url.path.count, 120)
        return score
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
        let bufferSize = 64 * 1024

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
