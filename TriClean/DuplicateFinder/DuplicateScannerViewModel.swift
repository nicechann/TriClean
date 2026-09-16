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
import os.log

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
    /// 뒤늦게 끝난 이전 스캔이 새 스캔의 상태를 덮어쓰지 않도록 하는 세대 번호.
    private var scanGeneration: UInt = 0

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

    private let bookmarks = SecurityScopedBookmarkStore.shared

    init() {
        scanFolderURL = bookmarks.resolveURL(for: .duplicateScanFolder)
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
            bookmarks.trySave(url: url, for: .duplicateScanFolder)
            // 이전 폴더의 보안 스코프 접근을 반드시 닫는다.
            releaseFolderAccess()
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
        scanGeneration &+= 1
        let generation = scanGeneration

        isScanning = true
        groups = []
        progress = 0
        totalFilesScanned = 0
        lastCleanupResult = nil

        let minBytes = Int64(minFileSizeKB) * 1024
        let rootURL = folderURL.standardizedFileURL

        // 결과가 표시되는 동안 접근을 유지한다. QuickLook 미리보기는 파일을 **읽으므로**
        // 스캔이 끝난 뒤에도 스코프가 열려 있어야 내용이 보인다.
        // 스코프는 북마크에서 복원한 원본 URL(`folderURL`)로 시작해야 한다.
        beginFolderAccess(folderURL)

        scanTask = Task {
            let started = rootURL.startAccessingSecurityScopedResource()
            defer { if started { rootURL.stopAccessingSecurityScopedResource() } }

            // ✅ 접근 권한 검증: 조용히 "중복 없음"으로 끝내지 않고 폴더 재선택을 안내한다.
            //    [수정] 기존 `!started && !readable`은 스코프는 열렸지만 북마크가 stale해서
            //    실제로는 읽을 수 없는 경우를 통과시켜, 빈 결과를 정상 결과처럼 보여줬다.
            //    JunkScannerViewModel과 동일하게 읽기 가능 여부만으로 판정한다.
            let readable = await Task.detached(priority: .utility) {
                Self.isDirectoryReadable(rootURL)
            }.value
            if !readable {
                guard generation == scanGeneration else { return }
                scanTask = nil
                phase = .accessDenied
                isScanning = false
                progress = 0
                statusMessage = "duplicate.status.access_denied".localized
                return
            }

            // Phase 1: 파일 수집
            guard generation == scanGeneration else { return }
            phase = .collectingFiles
            statusMessage = "duplicate.status.collecting".localized

            let collectWorker = Task.detached(priority: .utility) {
                Self.collectFiles(in: rootURL, minBytes: minBytes)
            }
            let allFiles = await withTaskCancellationHandler {
                await collectWorker.value
            } onCancel: {
                // detached 작업은 부모 Task 취소를 자동 상속하지 않으므로 직접 전달한다.
                collectWorker.cancel()
            }

            guard generation == scanGeneration, !Task.isCancelled else { return }
            totalFilesScanned = allFiles.count
            statusMessage = "duplicate.status.found_files".localized(with: allFiles.count)

            guard !allFiles.isEmpty else {
                finishScan(generation: generation)
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
                finishScan(generation: generation)
                return
            }

            // Phase 3: 부분 해시 (처음 4KB)
            phase = .hashingPartial
            let partialHashWorker = Task.detached(priority: .utility) {
                Self.groupByPartialHash(sizeGroups: sizeGroups)
            }
            let partialGroups = await withTaskCancellationHandler {
                await partialHashWorker.value
            } onCancel: {
                partialHashWorker.cancel()
            }

            guard generation == scanGeneration, !Task.isCancelled else { return }
            let partialCandidates = partialGroups.values.filter { $0.count >= 2 }
            statusMessage = "duplicate.status.partial_hash_matches".localized(with: partialCandidates.count)

            guard !partialCandidates.isEmpty else {
                finishScan(generation: generation)
                return
            }

            // Phase 4: 전체 해시
            // ✅ [수정] 파일 하나당 Task.detached를 만들어 순차 await 하던 구조를
            //    코어 수만큼의 워커로 병렬 처리하도록 변경했다. 진행률도 파일마다
            //    MainActor로 넘기지 않고 워커 청크 단위로만 갱신한다.
            phase = .hashingFull
            let hashTargets = partialCandidates.flatMap { $0 }
            let totalToHash = hashTargets.count
            let workerCount = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
            let chunkSize = max(1, (totalToHash + workerCount - 1) / workerCount)

            var hashSlices: [[FileCandidate]] = []
            var sliceStart = 0
            while sliceStart < totalToHash {
                let sliceEnd = min(sliceStart + chunkSize, totalToHash)
                hashSlices.append(Array(hashTargets[sliceStart..<sliceEnd]))
                sliceStart = sliceEnd
            }

            var fullHashMap: [String: [FileCandidate]] = [:]
            var hashedCount = 0

            await withTaskGroup(of: FullHashChunk.self) { group in
                for slice in hashSlices {
                    group.addTask {
                        var hashed: [HashedFile] = []
                        hashed.reserveCapacity(slice.count)
                        var processed = 0

                        for file in slice {
                            if Task.isCancelled { break }
                            processed += 1
                            if let hash = Self.fullHash(of: file.url) {
                                hashed.append(HashedFile(hash: hash, file: file))
                            }
                        }

                        return FullHashChunk(hashed: hashed, processedCount: processed)
                    }
                }

                for await chunk in group {
                    for entry in chunk.hashed {
                        fullHashMap[entry.hash, default: []].append(entry.file)
                    }
                    hashedCount += chunk.processedCount

                    guard generation == scanGeneration else { continue }
                    progress = totalToHash > 0 ? Double(hashedCount) / Double(totalToHash) : 0
                    statusMessage = "duplicate.status.hashing_full_progress".localized(with: hashedCount, totalToHash)
                }
            }

            guard generation == scanGeneration, !Task.isCancelled else { return }

            // 그룹 구성은 파일마다 lstat을 수행하므로(하드링크 판별·정체성 스냅샷)
            // 메인 액터가 아니라 백그라운드에서 처리한다.
            let groupWorker = Task.detached(priority: .utility) { [fullHashMap, rootURL] in
                Self.buildDuplicateGroups(from: fullHashMap, rootURL: rootURL)
            }
            let finalGroups = await withTaskCancellationHandler {
                await groupWorker.value
            } onCancel: {
                groupWorker.cancel()
            }

            guard generation == scanGeneration else { return }
            guard !Task.isCancelled else {
                finishScan(generation: generation, cancelled: true)
                return
            }

            groups = finalGroups
            finishScan(generation: generation)
        }
    }

    /// 진행 중인 스캔을 중지한다.
    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        isScanning = false
        phase = .idle
        progress = 0
        statusMessage = "storage.msg.canceled".localized
    }

    /// 스캔 종료 처리. 이미 새 스캔이 시작된 뒤라면(세대 불일치) 아무것도 하지 않는다.
    /// 취소된 스캔을 "완료"로 표시하던 문제도 함께 정리한다.
    private func finishScan(generation: UInt, cancelled: Bool = false) {
        guard generation == scanGeneration else { return }
        scanTask = nil
        isScanning = false

        guard !cancelled else {
            phase = .idle
            progress = 0
            statusMessage = "storage.msg.canceled".localized
            return
        }

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

    // MARK: - 보안 스코프 유지

    /// 결과 목록이 가리키는 폴더의 접근을 유지합니다(미리보기·Finder 열기용).
    /// 다른 폴더로 바뀌면 이전 접근을 닫고 새로 엽니다.
    private var accessedFolderURL: URL? = nil
    private var folderAccessToken: SecurityScopedAccessToken? = nil

    private func beginFolderAccess(_ url: URL) {
        if accessedFolderURL == url, folderAccessToken != nil { return }
        releaseFolderAccess()
        folderAccessToken = SecurityScopedAccessToken(url: url)
        accessedFolderURL = url
    }

    private func releaseFolderAccess() {
        folderAccessToken?.stop()
        folderAccessToken = nil
        accessedFolderURL = nil
    }

    // MARK: - Finder / 미리보기

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 삭제 판단 전에 내용을 확인할 수 있도록 미리보기 대상을 만듭니다.
    func previewTarget(for file: DuplicateFile, in group: DuplicateGroup) -> QuickLookTarget {
        QuickLookTarget(url: file.url, sizeText: group.fileSizeString)
    }

    // MARK: - 삭제

    /// 삭제 작업의 단위 (백그라운드 Task에서 사용)
    nonisolated private struct DeleteTarget: Sendable {
        let fileID: UUID
        let url: URL
        let perFileSize: Int64
        let fileIdentity: FileIdentitySnapshot?
    }

    nonisolated private struct KeeperSnapshot: Sendable {
        let url: URL
        let fileIdentity: FileIdentitySnapshot?
    }

    /// 삭제 결과의 단위
    nonisolated private struct DeleteGroupSnapshot: Sendable {
        let keeper: KeeperSnapshot?
        let targets: [DeleteTarget]
    }

    nonisolated private struct DeleteOutcome: Sendable {
        let succeeded: Set<UUID>
        let deletedCount: Int
        let failedCount: Int
        let deletedBytes: Int64
        let excludedCount: Int
        /// 보안 스코프 접근 자체가 실패한 경우. 삭제를 시도조차 하지 않았음을 뜻한다.
        var accessDenied: Bool = false
    }

    /// 삭제 직전에 보안 스코프 안에서 보존본과 모든 대상 경로를 재검증합니다.
    func deleteDuplicates() {
        guard StoreManager.shared.isPurchased else { return }
        // ⚠️ 보안 스코프는 북마크에서 복원한 **원본 URL**로 시작해야 한다.
        //    standardizedFileURL은 /var → /private/var 같은 심볼릭 링크를 해석해 경로 문자열을
        //    바꾸므로 스코프가 열리지 않을 수 있다(SecurityScopedBookmarks.swift 주석 참조).
        //    경로 경계 검증에만 standardized 형태를 쓴다.
        guard let scopeURL = scanFolderURL else { return }
        let validationScope = scopeURL.standardizedFileURL
        guard canDeleteSelected else {
            statusMessage = "duplicate.status.nothing_selected".localized
            return
        }
        guard !isDeleting else { return }

        let snapshots: [DeleteGroupSnapshot] = groups.map { group in
            DeleteGroupSnapshot(
                keeper: group.keptFile.map {
                    KeeperSnapshot(
                        url: $0.url.standardizedFileURL,
                        fileIdentity: $0.fileIdentity
                    )
                },
                targets: group.files.filter { !$0.isKeep }.map {
                    DeleteTarget(
                        fileID: $0.id,
                        url: $0.url.standardizedFileURL,
                        perFileSize: group.fileSize,
                        fileIdentity: $0.fileIdentity
                    )
                }
            )
        }

        isDeleting = true
        statusMessage = "duplicate.status.cleanup_running".localized

        Task { @MainActor [weak self, snapshots, scopeURL, validationScope] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> DeleteOutcome in
                let started = scopeURL.startAccessingSecurityScopedResource()
                guard started else {
                    Logger(subsystem: "com.nicechann.TriClean", category: "DuplicateCleanup").error(
                        "Security-scoped access failed for \(scopeURL.path, privacy: .private)"
                    )
                    return DeleteOutcome(
                        succeeded: [],
                        deletedCount: 0,
                        failedCount: 0,
                        deletedBytes: 0,
                        excludedCount: 0,
                        accessDenied: true
                    )
                }
                defer { scopeURL.stopAccessingSecurityScopedResource() }

                return await Self.prepareAndPerformDeletion(
                    snapshots: snapshots,
                    folder: validationScope
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
        var candidates: [DeleteTarget] = []
        var excludedCount = 0

        for snapshot in snapshots {
            guard let keeper = snapshot.keeper,
                  DeletionSafety.isContained(keeper.url, inScope: folder),
                  keeper.fileIdentity?.matchesCurrentFile(at: keeper.url) == true else {
                excludedCount += snapshot.targets.count
                continue
            }

            let currentTargets = snapshot.targets.filter {
                $0.fileIdentity?.matchesCurrentFile(at: $0.url) == true
            }
            excludedCount += snapshot.targets.count - currentTargets.count
            candidates.append(contentsOf: currentTargets)
        }

        let trashed = await TrashService.sanitizeAndMoveToTrash(
            candidates,
            scopes: [.descendants(of: folder)],
            url: \.url,
            identity: \.fileIdentity,
            logCategory: "DuplicateCleanup"
        )

        return DeleteOutcome(
            succeeded: Set(trashed.succeeded.map(\.fileID)),
            deletedCount: trashed.succeededCount,
            failedCount: trashed.failedCount,
            deletedBytes: trashed.succeeded.reduce(0) { $0 + $1.perFileSize },
            excludedCount: excludedCount + trashed.excludedCount
        )
    }

    private func applyDeleteOutcome(_ outcome: DeleteOutcome) {
        // 스코프를 열지 못했다면 삭제를 시도하지 않았다. 결과 목록을 건드리지 않고 안내만 한다.
        guard !outcome.accessDenied else {
            statusMessage = "common.permission_needed".localized
            return
        }

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

    // MARK: - 파일 수집 (백그라운드)

    nonisolated private struct FileCandidate: Sendable {
        let url: URL
        /// Duplicate detection must use the logical file size. Allocated size can differ
        /// for sparse/compressed files and would split identical files before hashing.
        let size: Int64
        let modDate: Date?
    }

    /// 전체 해시 병렬 계산 결과 단위.
    nonisolated private struct HashedFile: Sendable {
        let hash: String
        let file: FileCandidate
    }

    nonisolated private struct FullHashChunk: Sendable {
        let hashed: [HashedFile]
        /// 진행률 계산용. 해시에 실패한 파일도 처리한 것으로 센다.
        let processedCount: Int
    }

    /// 정렬을 위한 중간 표현.
    /// (도입 당시에는 `DuplicateGroup`이 MainActor 격리라 nonisolated 컨텍스트에서
    ///  `reclaimableBytes`를 읽을 수 없었다. 지금은 `DuplicateGroup`도 nonisolated지만,
    ///  정렬 키를 미리 구해 그룹마다 재계산하지 않는 이점이 남아 있어 유지한다.)
    nonisolated private struct PendingDuplicateGroup: Sendable {
        let reclaimableBytes: Int64
        let hash: String
        let files: [FileCandidate]
    }

    /// 전체 해시가 같은 파일들을 중복 그룹으로 묶는다.
    /// 병렬 해시 결과의 도착 순서와 무관하게 같은 결과가 나오도록 경로순으로 정렬한다.
    nonisolated private static func buildDuplicateGroups(
        from fullHashMap: [String: [FileCandidate]],
        rootURL: URL
    ) -> [DuplicateGroup] {
        var pending: [PendingDuplicateGroup] = []

        for hash in fullHashMap.keys.sorted() {
            guard !Task.isCancelled else { break }
            guard let files = fullHashMap[hash], files.count >= 2 else { continue }

            let ordered = files.sorted { $0.url.path < $1.url.path }
            let uniqueFiles = removeHardlinkedFiles(from: ordered)
            guard uniqueFiles.count >= 2 else { continue }

            // DuplicateGroup.reclaimableBytes와 동일한 계산식:
            // (파일 수 - 1) × 개별 파일 크기
            let perFileSize = uniqueFiles[0].size
            let reclaimableBytes = Int64(max(0, uniqueFiles.count - 1)) * perFileSize

            pending.append(PendingDuplicateGroup(
                reclaimableBytes: reclaimableBytes,
                hash: hash,
                files: uniqueFiles
            ))
        }

        pending.sort { $0.reclaimableBytes > $1.reclaimableBytes }

        var groups: [DuplicateGroup] = []
        groups.reserveCapacity(pending.count)
        for entry in pending {
            guard !Task.isCancelled else { break }
            groups.append(DuplicateGroup(
                hash: entry.hash,
                fileSize: entry.files[0].size,
                files: makeDuplicateFiles(from: entry.files, rootURL: rootURL)
            ))
        }
        return groups
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
        ] + CloudFileStatus.requiredResourceKeys

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [FileCandidate] = []
        files.reserveCapacity(1000)
        var skippedCloudFileCount = 0

        for case let url as URL in enumerator {
            guard !Task.isCancelled else {
                enumerator.skipDescendants()
                break
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }

            // ⚠️ 클라우드 전용(자리표시자) 파일은 **해시를 계산하기 전에** 반드시 제외한다.
            //    아래 `logicalSize`는 논리 크기라 자리표시자도 크기 그룹핑을 통과하는데,
            //    그다음 단계의 `partialHash`가 4KB를 읽는 순간 macOS가 파일 전체를 내려받는다.
            //    디스크를 비우려는 스캔이 오히려 디스크를 채우게 된다.
            //    (어차피 로컬 점유가 0이라 지워도 공간이 늘지 않는다.)
            guard !CloudFileStatus.isDataless(values) else {
                skippedCloudFileCount += 1
                continue
            }

            let logicalSize = Int64(values.fileSize ?? 0)
            guard logicalSize >= minBytes else { continue }

            files.append(FileCandidate(
                url: url,
                size: logicalSize,
                modDate: values.contentModificationDate
            ))
        }

        if skippedCloudFileCount > 0 {
            Logger(subsystem: "com.nicechann.TriClean", category: "DuplicateScan").info(
                "Skipped \(skippedCloudFileCount) cloud-only files to avoid triggering downloads"
            )
        }

        return files
    }

    // MARK: - 해시 (백그라운드)

    nonisolated private static func groupByPartialHash(
        sizeGroups: [Int64: [FileCandidate]]
    ) -> [String: [FileCandidate]] {
        var hashMap: [String: [FileCandidate]] = [:]

        for (_, group) in sizeGroups where group.count >= 2 {
            guard !Task.isCancelled else { break }
            for file in group {
                guard !Task.isCancelled else { break }
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
            guard !Task.isCancelled else { break }
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
    ///
    /// ⚠️ `readData(ofLength:)`는 읽기 실패 시 `NSFileHandleOperationException`을 raise하며
    ///    Swift에서 catch할 수 없어 프로세스가 죽는다. 네트워크 볼륨 끊김·외장 디스크 분리·
    ///    권한 오류에서 현실적으로 발생하므로 throwing API인 `read(upToCount:)`를 쓴다.
    nonisolated private static func partialHash(of url: URL, bytes: Int = 4096) -> String? {
        guard !Task.isCancelled else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        guard !Task.isCancelled, !data.isEmpty else { return nil }

        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 파일 전체의 SHA-256 해시 (스트리밍)
    ///
    /// 읽기 오류는 `nil`로 보고한다. 중간까지만 읽고 만든 해시를 돌려주면 서로 다른 파일이
    /// 같은 해시로 묶여 **잘못된 중복 판정 → 잘못된 삭제**로 이어지므로, 부분 성공은 허용하지 않는다.
    nonisolated private static func fullHash(of url: URL) -> String? {
        guard !Task.isCancelled else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 64 * 1024

        while true {
            guard !Task.isCancelled else { return nil }

            let chunk: Data?
            do {
                chunk = try autoreleasepool { try handle.read(upToCount: bufferSize) }
            } catch {
                Logger(subsystem: "com.nicechann.TriClean", category: "DuplicateScan").warning(
                    "Full hash read failed path=\(url.path, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
                )
                return nil
            }

            // `read(upToCount:)`는 EOF에서 nil 또는 빈 Data를 돌려준다.
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }

        guard !Task.isCancelled else { return nil }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
