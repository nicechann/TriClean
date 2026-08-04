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
//  ✅ [수정 v4]
//   - deleteDuplicates: 백그라운드 작업을 Task.detached로 명확히 분리하고 UI 반영만 MainActor에서 수행.
//   - NSWorkspace.recycle fallback은 MainActor helper로 이동해 AppKit 접근을 안전하게 처리.
//
//  ✅ [수정 v3]
//   - deleteDuplicates: 메인 스레드 동기 trashItem → Task로 분리해 UI 멈춤 방지.
//   - trashItem 실패 시 NSWorkspace.recycle fallback 추가 (JunkScannerViewModel과 동일 패턴).
//   - DuplicateGroup.fileSize → DuplicateGroup.perFileSize 의도 명확화 주석.
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
    @Published var isDeleting: Bool = false
    @Published var phase: DuplicateScanPhase = .idle
    @Published var progress: Double = 0       // 0.0 ~ 1.0
    @Published var statusMessage: String = ""
    @Published var scanFolderURL: URL? = nil
    @Published var minFileSizeKB: Int = 100    // 최소 파일 크기 (KB)
    @Published var lastCleanupResult: DuplicateCleanupResult? = nil

    private var scanTask: Task<Void, Never>? = nil

    // MARK: - Computed

    var totalDuplicateGroups: Int { groups.count }

    var totalReclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    var totalReclaimableString: String {
        ByteCountFormatter.string(fromByteCount: totalReclaimableBytes, countStyle: .file)
    }

    /// ✅ [수정] 비-@Published 저장 프로퍼티를 참조해 뷰가 갱신되지 않던 문제.
    @Published private(set) var totalFilesScanned: Int = 0

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
            phase = .idle
            statusMessage = ""
        }
    }

    // MARK: - 스캔

    func scan() {
        guard let folderURL = scanFolderURL else { return }
        guard !isScanning else { return }

        scanTask?.cancel()
        isScanning = true
        groups = []
        progress = 0
        totalFilesScanned = 0
        lastCleanupResult = nil

        let minBytes = Int64(minFileSizeKB) * 1024
        let rootURL = folderURL.standardizedFileURL

        scanTask = Task {
            let started = rootURL.startAccessingSecurityScopedResource()
            defer { if started { rootURL.stopAccessingSecurityScopedResource() } }

            // ✅ 접근 권한 검증: 보안 스코프 접근이 실패하고(코드 서명 변경 등으로 북마크가
            //    무효화된 경우) 실제 디렉터리 읽기도 불가하면, 조용히 "중복 없음"으로 끝내지 않고
            //    사용자에게 폴더 재선택을 안내한다.
            let readable = await Task.detached(priority: .utility) {
                Self.isDirectoryReadable(rootURL)
            }.value
            if !started && !readable {
                phase = .accessDenied
                isScanning = false
                progress = 0
                statusMessage = "duplicate.status.access_denied".localized
                return
            }

            // Phase 1: 파일 수집
            phase = .collectingFiles
            statusMessage = "duplicate.status.collecting".localized

            let allFiles = await Task.detached(priority: .utility) {
                Self.collectFiles(in: rootURL, minBytes: minBytes)
            }.value

            totalFilesScanned = allFiles.count
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
                    let uniqueFiles = Self.removeHardlinkedFiles(from: files)
                    guard uniqueFiles.count >= 2 else { continue }

                    let dupFiles = Self.makeDuplicateFiles(from: uniqueFiles, rootURL: rootURL)

                    finalGroups.append(DuplicateGroup(
                        hash: hash,
                        fileSize: uniqueFiles[0].size,
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

    /// 삭제 작업의 단위 (백그라운드 Task에서 사용)
    private struct DeleteTarget: Sendable {
        let fileID: UUID
        let url: URL
        let perFileSize: Int64
    }

    /// 삭제 결과의 단위
    private struct DeleteGroupSnapshot: Sendable {
        let keeperURL: URL?
        let targets: [DeleteTarget]
    }

    private struct DeleteOutcome: Sendable {
        let succeeded: Set<UUID>
        let deletedCount: Int
        let failedCount: Int
        let deletedBytes: Int64
        let excludedCount: Int
    }

    /// 삭제 직전에 보안 스코프 안에서 보존본과 모든 대상 경로를 재검증합니다.
    func deleteDuplicates() {
        guard let folder = scanFolderURL?.standardizedFileURL else { return }
        guard canDeleteSelected else {
            statusMessage = "duplicate.status.nothing_selected".localized
            return
        }
        guard !isDeleting else { return }

        let snapshots: [DeleteGroupSnapshot] = groups.map { group in
            DeleteGroupSnapshot(
                keeperURL: group.keptFile?.url.standardizedFileURL,
                targets: group.files.filter { !$0.isKeep }.map {
                    DeleteTarget(fileID: $0.id, url: $0.url.standardizedFileURL, perFileSize: group.fileSize)
                }
            )
        }

        isDeleting = true
        statusMessage = "duplicate.status.cleanup_running".localized

        Task { @MainActor [weak self, snapshots, folder] in
            let outcome = await Task.detached(priority: .userInitiated) {
                let started = folder.startAccessingSecurityScopedResource()
                defer { if started { folder.stopAccessingSecurityScopedResource() } }

                return await Self.prepareAndPerformDeletion(
                    snapshots: snapshots,
                    folder: folder
                )
            }.value

            guard let self else { return }
            self.applyDeleteOutcome(outcome)
            self.isDeleting = false
        }
    }

    nonisolated private static func prepareAndPerformDeletion(
        snapshots: [DeleteGroupSnapshot],
        folder: URL
    ) async -> DeleteOutcome {
        let fm = FileManager.default
        var candidates: [DeleteTarget] = []
        var excludedCount = 0

        for snapshot in snapshots {
            guard let keeperURL = snapshot.keeperURL,
                  DeletionSafety.isContained(keeperURL, inScope: folder),
                  fm.fileExists(atPath: keeperURL.path) else {
                excludedCount += snapshot.targets.count
                continue
            }
            candidates.append(contentsOf: snapshot.targets)
        }

        let sanitized = DeletionSafety.sanitize(candidates, scope: folder, url: \.url)
        excludedCount += sanitized.rejectedCount

        guard !sanitized.accepted.isEmpty else {
            return DeleteOutcome(
                succeeded: [],
                deletedCount: 0,
                failedCount: 0,
                deletedBytes: 0,
                excludedCount: excludedCount
            )
        }

        let deletion = await performDeletion(targets: sanitized.accepted)
        return DeleteOutcome(
            succeeded: deletion.succeeded,
            deletedCount: deletion.deletedCount,
            failedCount: deletion.failedCount,
            deletedBytes: deletion.deletedBytes,
            excludedCount: excludedCount
        )
    }

    private func applyDeleteOutcome(_ outcome: DeleteOutcome) {
        for i in groups.indices {
            groups[i].files.removeAll { outcome.succeeded.contains($0.id) }
        }
        groups.removeAll { $0.files.count <= 1 }

        lastCleanupResult = DuplicateCleanupResult(
            deletedCount: outcome.deletedCount,
            deletedBytes: outcome.deletedBytes,
            failedCount: outcome.failedCount
        )

        if outcome.deletedCount == 0 {
            statusMessage = outcome.excludedCount > 0
                ? "duplicate.status.revalidate_needed".localized(with: outcome.excludedCount)
                : "duplicate.status.cleanup_failed".localized
        } else if outcome.failedCount > 0 || outcome.excludedCount > 0 {
            statusMessage = "duplicate.status.cleanup_summary".localized(
                with: outcome.deletedCount,
                ByteCountFormatter.string(fromByteCount: outcome.deletedBytes, countStyle: .file),
                outcome.failedCount,
                outcome.excludedCount
            )
        } else {
            statusMessage = "duplicate.status.cleanup_done".localized(
                with: outcome.deletedCount,
                ByteCountFormatter.string(fromByteCount: outcome.deletedBytes, countStyle: .file)
            )
        }
    }

    /// 백그라운드에서 trashItem + (실패 시) NSWorkspace.recycle fallback.
    private nonisolated static func performDeletion(targets: [DeleteTarget]) async -> DeleteOutcome {
        let fm = FileManager.default
        var succeeded = Set<UUID>()
        var deletedCount = 0
        var deletedBytes: Int64 = 0
        var failedCount = 0

        for target in targets {
            var didSucceed = false

            do {
                try fm.trashItem(at: target.url, resultingItemURL: nil)
                didSucceed = true
            } catch {
                // Fallback: NSWorkspace.recycle (AppKit 접근은 MainActor에서 수행)
                didSucceed = await recycleWithWorkspace(target.url)
            }

            if didSucceed {
                succeeded.insert(target.fileID)
                deletedCount += 1
                deletedBytes += target.perFileSize
            } else {
                failedCount += 1
            }
        }

        return DeleteOutcome(
            succeeded: succeeded,
            deletedCount: deletedCount,
            failedCount: failedCount,
            deletedBytes: deletedBytes,
            excludedCount: 0
        )
    }

    @MainActor
    private static func recycleWithWorkspace(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    // MARK: - 파일 수집 (백그라운드)

    private struct FileCandidate: Sendable {
        let url: URL
        /// Duplicate detection must use the logical file size. Allocated size can differ
        /// for sparse/compressed files and would split identical files before hashing.
        let size: Int64
        let modDate: Date?
    }

    /// 디렉터리 읽기 가능 여부 프로브. 나열이 성공하면 true(빈 폴더 포함),
    /// 권한 실패(보안 스코프 무효 등) 시 throw → false.
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

    nonisolated private static func collectFiles(in root: URL, minBytes: Int64) -> [FileCandidate] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
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

            let logicalSize = Int64(values.fileSize ?? 0)
            guard logicalSize >= minBytes else { continue }

            files.append(FileCandidate(
                url: url,
                size: logicalSize,
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

    /// ✅ [개명] removeAliasedFiles → removeHardlinkedFiles
    ///   lstat은 심볼릭 링크 자체를 가리키므로 hardlink는 (dev, inode)로 합쳐지지만
    ///   심볼릭 링크는 합쳐지지 않습니다. 함수명을 의도에 맞게 변경.
    private nonisolated static func removeHardlinkedFiles(from files: [FileCandidate]) -> [FileCandidate] {
        var seenIdentityKeys = Set<String>()
        var uniqueFiles: [FileCandidate] = []
        uniqueFiles.reserveCapacity(files.count)

        for file in files {
            if let identityKey = fileIdentityKey(of: file.url) {
                if seenIdentityKeys.insert(identityKey).inserted {
                    uniqueFiles.append(file)
                }
            } else {
                uniqueFiles.append(file)
            }
        }

        return uniqueFiles
    }

    private nonisolated static func fileIdentityKey(of url: URL) -> String? {
        var info = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return lstat(path, &info)
        }

        guard result == 0 else { return nil }
        return "\(UInt64(info.st_dev)):\(UInt64(info.st_ino))"
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

    // 테스트에서 접근할 수 있도록 internal (호출부는 여전히 내부 전용)
    nonisolated static func recommendedKeepIndex(for files: [DuplicateFile], rootURL: URL) -> Int {
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

    nonisolated static func recommendationScore(for file: DuplicateFile, rootURL: URL) -> Int {
        let loweredName = file.url.lastPathComponent.lowercased()
        // ✅ 다국어 "사본/복사" 마커 확장 (앱 지원 언어: en/ko/ja/de/es/fr)
        let duplicateMarkers = [
            "copy", "duplicate", "backup",
            "사본", "복사본", "백업",
            "コピー", "複製", "バックアップ",
            "kopie", "duplikat", "sicherung",
            "copia", "duplicado", "respaldo",
            "copie", "sauvegarde"
        ]

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

        // ✅ 경로 길이 페널티 약화 (-120 → -30 cap) — 깊은 경로의 깨끗한 보관 파일이
        //    다른 모든 신호를 압도하지 않도록.
        score -= min(file.url.path.count / 4, 30)
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
