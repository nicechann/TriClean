//
//  PhotoScannerViewModel.swift
//  TriClean
//
//  사진 관리자 ViewModel.
//  샌드박스 제약: 사용자가 NSOpenPanel으로 선택한 폴더만 접근(보안 스코프 북마크로 유지).
//
//  ✅ 1단계(스캐폴딩):
//   - 선택 폴더와 하위 폴더의 이미지 파일을 수집하고 픽셀 크기를 읽어옵니다.
//   - 유사/흐릿/스크린샷 분류는 이후 단계에서 추가됩니다.
//   - 다른 스캐너와 동일하게 백그라운드 수집 → MainActor UI 반영 패턴을 따릅니다.
//

import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
import CoreServices
import ImageIO
import CoreGraphics   // Spotlight 메타데이터(kMDItemIsScreenCapture)

@MainActor
final class PhotoScannerViewModel: ObservableObject {

    // MARK: - Published

    @Published var items: [PhotoItem] = []
    @Published var isScanning: Bool = false
    @Published var phase: PhotoScanPhase = .idle
    @Published var progress: Double = 0
    @Published var statusMessage: String = ""
    @Published var scanFolderURL: URL? = nil
    @Published var lastScanDate: Date? = nil

    @Published var selectedCategory: PhotoCategory = .all

    // 3단계: 흐릿한 사진 분석(주문형)
    @Published var isAnalyzingBlur: Bool = false
    @Published var isBlurAnalyzed: Bool = false
    @Published var blurProgress: Double = 0

    // 4단계: 유사 사진 분석(주문형)
    @Published var similarGroups: [PhotoGroup] = []
    @Published var isAnalyzingSimilar: Bool = false
    @Published var isSimilarAnalyzed: Bool = false
    @Published var similarProgress: Double = 0

    // 5단계: 선택 항목 휴지통 이동 상태
    @Published var isDeleting: Bool = false
    @Published var deleteStatusMessage: String? = nil

    private var scanTask: Task<Void, Never>? = nil
    private var blurTask: Task<Void, Never>? = nil
    private var similarTask: Task<Void, Never>? = nil

    /// 라플라시안 분산 임계값. 이 값보다 낮으면 흐릿한 것으로 판단(낮을수록 더 흐릿).
    /// 콘텐츠 의존적이라 실사용 후 조정이 필요할 수 있습니다.
    static let blurThreshold: Double = 60.0

    /// dHash 해밍 거리 임계값. 이 값 이하면 '유사'로 묶음(낮을수록 더 엄격).
    /// ✅ [수정] 64비트 dHash에서 10은 지나치게 관대해, 어둡거나 단조로운 사진
    ///   (야경·문서 스캔·화이트보드)이 서로 무관해도 같은 그룹으로 묶였다.
    ///   그룹 전체 선택 후 일괄 삭제가 한 번의 클릭으로 일어나므로 보수적으로 조정.
    static let similarHammingThreshold: Int = 6

    /// 원본 가로세로 비율 차이 허용 범위. 서로 다른 방향(가로/세로)은 항상 제외하고,
    /// 같은 방향에서도 비율 차이가 5%를 넘으면 유사 사진 후보로 비교하지 않습니다.
    static let similarAspectRatioTolerance: Double = 0.05

    nonisolated struct SimilarHashCandidate: Sendable {
        let id: String
        let hash: UInt64
        let pixelWidth: Int
        let pixelHeight: Int
    }

    nonisolated struct PhotoDeletePreparation: Sendable {
        let targets: [PhotoItem]
        let excludedItemCount: Int
    }

    private var collectTask: Task<[PhotoItem], Never>? = nil   // 실제 취소 가능한 수집 작업

    // MARK: - Computed

    var totalCount: Int { items.count }

    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var hasResults: Bool { !items.isEmpty }

    var selectedFolderPath: String { scanFolderURL?.path ?? "" }

    // MARK: - Category (2단계)

    /// 현재 탐지가 구현된(선택 가능한) 카테고리. 단계가 진행되며 확장됩니다.
    let readyCategories: [PhotoCategory] = [.all, .screenshot, .blurry, .similar]

    var screenshotCount: Int { items.lazy.filter { $0.isScreenshot }.count }
    var blurCount: Int { items.lazy.filter { $0.isBlurry }.count }
    var similarPhotoCount: Int { similarGroups.reduce(0) { $0 + $1.count } }

    func count(for category: PhotoCategory) -> Int {
        switch category {
        case .all:        return totalCount
        case .screenshot: return screenshotCount
        case .blurry:     return blurCount
        case .similar:    return isSimilarAnalyzed ? similarPhotoCount : 0
        }
    }

    /// 선택된 카테고리에 해당하는 항목만 반환.
    var filteredItems: [PhotoItem] {
        switch selectedCategory {
        case .all:        return items
        case .screenshot: return items.filter { $0.isScreenshot }
        case .blurry:     return items.filter { $0.isBlurry }
        case .similar:    return []  // 유사는 similarGroups(그룹 뷰)로 표시
        }
    }

    // MARK: - Bookmark

    private let bookmarkKey = "TriClean.PhotoManager.FolderBookmark"

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
        guard !isDeleting else { return }

        let panel = NSOpenPanel()
        panel.title = "photos.select_folder.title".localized
        panel.message = "photos.select_folder.message".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            scanTask?.cancel()
            collectTask?.cancel()
            blurTask?.cancel()
            similarTask?.cancel()
            releaseFolderAccess()

            saveBookmark(url: url)
            scanFolderURL = url
            items = []
            selectedIDs = []
            selectedCategory = .all
            resetAnalysisState()
            deleteStatusMessage = nil
            phase = .idle
            progress = 0
            lastScanDate = nil
            statusMessage = "photos.status.ready".localized
        }
    }

    // MARK: - 스캔

    func scan() {
        guard let folderURL = scanFolderURL else { return }
        guard !isScanning, !isDeleting else { return }

        scanTask?.cancel()
        blurTask?.cancel()
        similarTask?.cancel()

        isScanning = true
        items = []
        progress = 0
        lastScanDate = nil
        selectedCategory = .all
        resetAnalysisState()
        selectedIDs = []
        deleteStatusMessage = nil
        phase = .collecting
        statusMessage = "photos.status.collecting".localized

        let root = folderURL.standardizedFileURL

        // ✅ 보안 스코프: 결과가 표시되는 동안(썸네일 lazy 로딩 포함) 접근을 유지.
        //    스캔 직후 닫으면 샌드박스에서 썸네일 파일 읽기가 거부되어 모두 실패합니다.
        guard beginFolderAccess(root) else {
            isScanning = false
            phase = .done
            statusMessage = "common.permission_needed".localized
            return
        }

        // ✅ 실제 취소 가능한 detached 작업(핸들을 보관해 직접 cancel)
        let collect = Task.detached(priority: .utility) { () -> [PhotoItem] in
            if Task.isCancelled { return [] }
            // 스크린샷은 Spotlight 일괄 질의 1회로 해결(파일별 호출 제거)
            let shots = Self.screenshotPaths(in: root)
            if Task.isCancelled { return [] }
            return Self.collectImages(in: root, screenshotPaths: shots)
        }
        collectTask = collect

        scanTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let collected = await collect.value
            // 폴더 접근은 여기서 닫지 않음 — 다음 스캔/폴더 변경 시 교체됨
            let cancelled = collect.isCancelled
            await MainActor.run {
                if cancelled {
                    self.items = []
                    self.finishScan(cancelled: true)
                } else {
                    // 큰 파일(용량 우선)이 먼저 보이도록 정렬
                    self.items = collected.sorted { $0.sizeBytes > $1.sizeBytes }
                    self.finishScan(cancelled: false)
                }
            }
        }
    }

    // MARK: - 보안 스코프 유지

    /// 현재 결과가 가리키는 폴더의 보안 스코프 접근을 유지(썸네일 로딩 위해).
    /// 다른 폴더로 바뀌면 이전 접근을 닫고 새 접근을 시작합니다.
    private var accessedFolderURL: URL? = nil
    private var folderAccessToken: SecurityScopedAccessToken? = nil

    private func beginFolderAccess(_ url: URL) -> Bool {
        if accessedFolderURL == url, folderAccessToken != nil { return true }
        releaseFolderAccess()

        guard let token = SecurityScopedAccessToken(url: url) else { return false }
        folderAccessToken = token
        accessedFolderURL = url
        return true
    }

    private func releaseFolderAccess() {
        folderAccessToken?.stop()
        folderAccessToken = nil
        accessedFolderURL = nil
    }

    func cancelScan() {
        statusMessage = "photos.status.cancelled".localized
        collectTask?.cancel()   // ✅ detached 수집 작업을 직접 취소(부모만 취소하면 전파 안 됨)
        scanTask?.cancel()
    }

    // MARK: - 흐릿한 사진 분석 (3단계, 주문형)

    func analyzeBlur() {
        guard !items.isEmpty, !isAnalyzingBlur, !isDeleting else { return }
        blurTask?.cancel()

        deleteStatusMessage = nil
        isAnalyzingBlur = true
        isBlurAnalyzed = false
        blurProgress = 0

        let snapshot = items                 // 값 복사(Sendable)
        let threshold = Self.blurThreshold
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)

        // 균등 분할(워커 수만큼)
        var slices: [[PhotoItem]] = []
        let per = (snapshot.count + workers - 1) / workers
        var start = 0
        while start < snapshot.count {
            let end = min(start + per, snapshot.count)
            slices.append(Array(snapshot[start..<end]))
            start = end
        }

        blurTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let blurry = await withTaskGroup(of: [String].self) { group -> Set<String> in
                for slice in slices {
                    group.addTask {
                        var local: [String] = []
                        for item in slice {
                            if Task.isCancelled { break }
                            if let v = Self.blurVariance(url: item.url), v < threshold {
                                local.append(item.id)
                            }
                        }
                        return local
                    }
                }
                var result = Set<String>()
                var done = 0
                for await ids in group {
                    result.formUnion(ids)
                    done += 1
                    let p = Double(done) / Double(max(slices.count, 1))
                    await MainActor.run { self.blurProgress = p }
                }
                return result
            }

            let cancelled = Task.isCancelled
            await MainActor.run {
                if cancelled {
                    self.isAnalyzingBlur = false
                    self.isBlurAnalyzed = false
                    self.blurProgress = 0
                    return
                }

                self.applyBlurFlags(blurry)
                self.isBlurAnalyzed = true
                self.isAnalyzingBlur = false
                self.blurProgress = 1
            }
        }
    }

    func cancelBlurAnalysis() {
        blurTask?.cancel()
        isAnalyzingBlur = false
        isBlurAnalyzed = false
        blurProgress = 0
    }

    private func applyBlurFlags(_ ids: Set<String>) {
        for i in items.indices {
            items[i].isBlurry = ids.contains(items[i].id)
        }
    }

    // MARK: - 유사 사진 분석 (4단계, 주문형, dHash + 해밍 거리)

    func analyzeSimilar() {
        guard !items.isEmpty, !isAnalyzingSimilar, !isDeleting else { return }
        similarTask?.cancel()

        deleteStatusMessage = nil
        isAnalyzingSimilar = true
        isSimilarAnalyzed = false
        similarProgress = 0
        similarGroups = []

        let snapshot = items
        let threshold = Self.similarHammingThreshold
        let aspectRatioTolerance = Self.similarAspectRatioTolerance
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)

        var slices: [[PhotoItem]] = []
        let per = (snapshot.count + workers - 1) / workers
        var start = 0
        while start < snapshot.count {
            let end = min(start + per, snapshot.count)
            slices.append(Array(snapshot[start..<end]))
            start = end
        }

        similarTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // 1) 병렬 dHash 계산. 픽셀 크기도 함께 전달해 비율이 다른 사진은 제외합니다.
            var hashes: [SimilarHashCandidate] = []
            await withTaskGroup(of: [SimilarHashCandidate].self) { group in
                for slice in slices {
                    group.addTask {
                        var local: [SimilarHashCandidate] = []
                        for item in slice {
                            if Task.isCancelled { break }
                            if let h = Self.differenceHash(url: item.url) {
                                local.append(SimilarHashCandidate(
                                    id: item.id,
                                    hash: h,
                                    pixelWidth: item.pixelWidth,
                                    pixelHeight: item.pixelHeight
                                ))
                            }
                        }
                        return local
                    }
                }
                var done = 0
                for await part in group {
                    hashes.append(contentsOf: part)
                    done += 1
                    let p = (Double(done) / Double(max(slices.count, 1))) * 0.85
                    await MainActor.run { self.similarProgress = p }
                }
            }

            if Task.isCancelled {
                await MainActor.run { self.finishSimilar(cancelled: true) }
                return
            }

            // 2) 클러스터링 (이미 .utility detached 컨텍스트라 그대로 계산)
            let groupIDs = Self.clusterByHash(
                hashes,
                threshold: threshold,
                aspectRatioTolerance: aspectRatioTolerance
            )

            if Task.isCancelled {
                await MainActor.run { self.finishSimilar(cancelled: true) }
                return
            }

            // 3) id → 현재 PhotoItem → PhotoGroup (삭제/새 스캔으로 사라진 항목은 제외)
            let cancelled = Task.isCancelled
            await MainActor.run {
                if cancelled {
                    self.finishSimilar(cancelled: true)
                    return
                }

                self.similarProgress = 1
                let byID = Dictionary(self.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                self.similarGroups = groupIDs.compactMap { ids in
                    let groupItems = ids.compactMap { byID[$0] }.sorted { $0.sizeBytes > $1.sizeBytes }
                    guard groupItems.count >= 2 else { return nil }
                    return PhotoGroup(id: groupItems.first?.id ?? ids.first ?? UUID().uuidString, items: groupItems)
                }
                .sorted { $0.count > $1.count }
                self.isSimilarAnalyzed = true
                self.isAnalyzingSimilar = false
            }
        }
    }

    func cancelSimilarAnalysis() {
        similarTask?.cancel()
        finishSimilar(cancelled: true)
    }

    private func finishSimilar(cancelled: Bool) {
        isAnalyzingSimilar = false
        if cancelled {
            similarProgress = 0
            isSimilarAnalyzed = false
        }
    }

    private func resetAnalysisState() {
        isAnalyzingBlur = false
        isBlurAnalyzed = false
        blurProgress = 0
        similarGroups = []
        isAnalyzingSimilar = false
        isSimilarAnalyzed = false
        similarProgress = 0
    }

    private func cancelRunningAnalysesForDeletion() {
        blurTask?.cancel()
        similarTask?.cancel()
        if isAnalyzingBlur {
            isAnalyzingBlur = false
            isBlurAnalyzed = false
            blurProgress = 0
        }
        if isAnalyzingSimilar {
            similarGroups = []
            finishSimilar(cancelled: true)
        }
    }

    // MARK: - 선택 / 삭제 (5단계)

    @Published var selectedIDs: Set<String> = []

    var selectedCount: Int { selectedIDs.count }

    var selectedBytes: Int64 {
        items.lazy.filter { self.selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedSizeString: String {
        ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)
    }

    func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }

    private var similarKeeperIDs: Set<String> {
        Set(similarGroups.compactMap { $0.items.first?.id })
    }

    private var visibleSelectionCandidates: [PhotoItem] {
        let visibleItems: [PhotoItem]
        switch selectedCategory {
        case .all:
            visibleItems = items
        case .screenshot:
            visibleItems = items.filter { $0.isScreenshot }
        case .blurry:
            visibleItems = isBlurAnalyzed ? items.filter { $0.isBlurry } : []
        case .similar:
            visibleItems = isSimilarAnalyzed ? similarGroups.flatMap { $0.items.dropFirst() } : []
        }

        let protectedIDs = similarKeeperIDs
        return visibleItems.filter { !protectedIDs.contains($0.id) }
    }

    var canSelectVisibleItems: Bool {
        guard !isDeleting else { return false }
        let candidates = visibleSelectionCandidates
        guard !candidates.isEmpty else { return false }
        return candidates.contains { !selectedIDs.contains($0.id) }
    }

    /// 현재 탭/필터에서 보이는 항목을 전체 선택합니다.
    /// 유사 그룹은 복구 안전성을 위해 각 그룹의 첫 장(keeper)을 선택하지 않습니다.
    func selectVisibleItems() {
        guard !isDeleting else { return }
        let candidates = visibleSelectionCandidates
        guard !candidates.isEmpty else { return }

        deleteStatusMessage = nil
        for item in candidates {
            selectedIDs.insert(item.id)
        }

        // 사용자가 이전에 keeper를 선택해둔 상태에서도 그룹 전체 삭제가 되지 않도록 한 번 더 보정합니다.
        selectedIDs.subtract(similarKeeperIDs)
    }

    /// 선택 토글. 유사 그룹은 최소 1장을 남기도록 마지막 한 장 선택을 막습니다.
    func toggleSelection(_ id: String) {
        guard !isDeleting else { return }
        deleteStatusMessage = nil

        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            return
        }
        // 선택하려는 경우: 유사 그룹이면 keep-1 가드
        if let group = similarGroups.first(where: { g in g.items.contains { $0.id == id } }) {
            let unselected = group.items.filter { !selectedIDs.contains($0.id) }.count
            if unselected <= 1 { return }   // 이 항목이 그룹의 마지막 미선택분 → 선택 거부
        }
        selectedIDs.insert(id)
    }

    /// 유사 그룹에서 첫 장(가장 큰 용량)만 남기고 나머지를 선택.
    func selectExtras(in group: PhotoGroup) {
        guard !isDeleting, let keeper = group.items.first else { return }
        deleteStatusMessage = nil

        // 사용자가 keeper를 미리 선택해둔 경우에도 그룹 전체가 선택되지 않도록 반드시 남깁니다.
        selectedIDs.remove(keeper.id)
        for item in group.items.dropFirst() {
            selectedIDs.insert(item.id)
        }
    }

    func clearSelection() {
        guard !isDeleting else { return }
        selectedIDs.removeAll()
        deleteStatusMessage = nil
    }

    /// 선택 항목을 휴지통으로 이동(복구 가능). 성공분만 모델에서 제거합니다.
    /// 유사 사진 그룹은 삭제 직전에 실제 보존본이 남아 있는지 다시 확인합니다.
    func deleteSelected() {
        guard StoreManager.shared.isPurchased else { return }
        guard !isDeleting else { return }
        let selected = items.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        guard let scope = scanFolderURL?.standardizedFileURL else {
            deleteStatusMessage = "photos.delete.status.invalid".localized
            return
        }

        cancelRunningAnalysesForDeletion()
        isDeleting = true
        deleteStatusMessage = "photos.delete.status.moving".localized(with: selected.count)

        let selectedSnapshot = selected
        let groupsSnapshot = similarGroups
        let scopeURL = scope

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // 보안 스코프를 연 상태에서 경로 존재 여부와 심볼릭 링크 경계를 재검증합니다.
            let started = scopeURL.startAccessingSecurityScopedResource()
            defer { if started { scopeURL.stopAccessingSecurityScopedResource() } }

            let preparation = Self.preparePhotoDeletion(
                selected: selectedSnapshot,
                similarGroups: groupsSnapshot,
                scope: scopeURL
            )

            var trashed = Set<String>()
            for item in preparation.targets {
                if Task.isCancelled { break }
                if await Self.moveToTrash(item) { trashed.insert(item.id) }
            }

            let result = trashed
            let failedCount = preparation.targets.count - result.count
            let excludedCount = preparation.excludedItemCount

            await MainActor.run {
                self.removeItems(result)
                self.isDeleting = false

                if preparation.targets.isEmpty {
                    self.deleteStatusMessage = "photos.delete.status.revalidate".localized(with: excludedCount)
                } else if failedCount > 0 || excludedCount > 0 {
                    self.deleteStatusMessage = "photos.delete.status.summary".localized(
                        with: result.count,
                        failedCount,
                        excludedCount
                    )
                } else {
                    self.deleteStatusMessage = "photos.delete.status.success".localized(with: result.count)
                }
            }
        }
    }

    /// 삭제 직전 재검증. 유사 그룹에서 선택되지 않은 실제 파일이 하나도 남지 않으면
    /// 해당 그룹의 선택 항목 전체를 제외해 원본까지 사라지는 상황을 방지합니다.
    nonisolated static func preparePhotoDeletion(
        selected: [PhotoItem],
        similarGroups: [PhotoGroup],
        scope: URL
    ) -> PhotoDeletePreparation {
        let selectedIDs = Set(selected.map(\.id))
        var unsafeSelectedIDs = Set<String>()

        // 스캔 이후 같은 경로의 파일이 교체된 경우 새 파일을 삭제하지 않습니다.
        for item in selected where item.fileIdentity?.matchesCurrentFile(at: item.url) != true {
            unsafeSelectedIDs.insert(item.id)
        }

        for group in similarGroups {
            let selectedInGroup = group.items.filter { selectedIDs.contains($0.id) }
            guard !selectedInGroup.isEmpty else { continue }

            let hasValidSurvivor = group.items.contains { item in
                !selectedIDs.contains(item.id)
                    && DeletionSafety.isContained(item.url, inScope: scope)
                    && item.fileIdentity?.matchesCurrentFile(at: item.url) == true
            }

            if !hasValidSurvivor {
                unsafeSelectedIDs.formUnion(selectedInGroup.map(\.id))
            }
        }

        let survivorProtectedCandidates = selected.filter { !unsafeSelectedIDs.contains($0.id) }
        let (targets, rejectedCount) = DeletionSafety.sanitize(
            survivorProtectedCandidates,
            scope: scope,
            url: \.url
        )

        return PhotoDeletePreparation(
            targets: targets,
            excludedItemCount: unsafeSelectedIDs.count + rejectedCount
        )
    }

    private func removeItems(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        // 유사 그룹 갱신: 1장 이하로 줄면 그룹 해제
        similarGroups = similarGroups.compactMap { g in
            let remaining = g.items.filter { !ids.contains($0.id) }
            guard remaining.count >= 2 else { return nil }
            return PhotoGroup(id: g.id, items: remaining)
        }
        selectedIDs.subtract(ids)
    }

    nonisolated private static func moveToTrash(_ item: PhotoItem) async -> Bool {
        guard item.fileIdentity?.matchesCurrentFile(at: item.url) == true else { return false }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            return true
        } catch {
            guard item.fileIdentity?.matchesCurrentFile(at: item.url) == true else { return false }
            // ✅ trashItem 실패 시 NSWorkspace.recycle로 폴백(다른 스캐너와 동일 패턴).
            return await recycleUsingWorkspace(item.url)
        }
    }

    @MainActor
    private static func recycleUsingWorkspace(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private func finishScan(cancelled: Bool) {
        isScanning = false
        phase = .done
        progress = 1.0
        if cancelled {
            lastScanDate = nil
            releaseFolderAccess()
            statusMessage = "photos.status.cancelled".localized
        } else {
            lastScanDate = Date()
            if items.isEmpty { releaseFolderAccess() }
            statusMessage = items.isEmpty
                ? "photos.status.empty".localized
                : "photos.status.found".localized(with: items.count)
        }
    }

    // MARK: - 이미지 수집 (백그라운드)

    nonisolated private static func collectImages(in root: URL, screenshotPaths: Set<String>) -> [PhotoItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .typeIdentifierKey,
            .isDirectoryKey,
            .isPackageKey
        ]

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var result: [PhotoItem] = []
        result.reserveCapacity(512)

        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }
            guard isImageFile(url: url, typeIdentifier: values.typeIdentifier) else { continue }

            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            // ImageIO 메타데이터만 읽어 원본을 디코딩하지 않고 픽셀 크기를 확보합니다.
            // EXIF 방향이 90도 회전된 사진은 표시 기준으로 가로/세로를 교환합니다.
            let dimensions = imagePixelDimensions(url: url)
            let screenshot = screenshotPaths.contains(url.path) || matchesScreenshotName(url)

            result.append(PhotoItem(
                url: url,
                sizeBytes: size,
                modificationDate: values.contentModificationDate,
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height,
                isScreenshot: screenshot
            ))
        }

        return result
    }

    /// 이미지 전체 디코딩 없이 픽셀 크기와 EXIF 방향만 읽습니다.
    nonisolated static func imagePixelDimensions(url: URL) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return (0, 0)
        }

        var width = widthNumber.intValue
        var height = heightNumber.intValue
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if [5, 6, 7, 8].contains(orientation) {
            swap(&width, &height)
        }
        return (max(width, 0), max(height, 0))
    }

    /// 스크린샷 경로 일괄 조회 (1순위, 빠름).
    /// Spotlight 인덱스에 kMDItemIsScreenCapture == 1 로 질의 — 파일별 호출 없이 한 번에.
    /// 인덱싱 안 된 볼륨이면 빈 집합 → 파일명 폴백(matchesScreenshotName)이 보완.
    nonisolated private static func screenshotPaths(in root: URL) -> Set<String> {
        let predicate = "kMDItemIsScreenCapture == 1"
        guard let query = MDQueryCreate(nil, predicate as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, [root.path] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }

        var paths = Set<String>()
        let count = MDQueryGetResultCount(query)
        var i = 0
        while i < count {
            if let raw = MDQueryGetResultAtIndex(query, i) {
                let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
                if let path = MDItemCopyAttribute(item, kMDItemPath) as? String {
                    paths.insert(path)
                }
            }
            i += 1
        }
        return paths
    }

    /// 스크린샷 파일명 패턴(영문/한글) + PNG. Spotlight 미적용분 보완(파일 열지 않음, 저렴).
    // 테스트에서 접근할 수 있도록 internal
    nonisolated static func matchesScreenshotName(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "png" else { return false }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        // ✅ [수정] en/ko만 지원해 ja/de/es/fr 사용자는 Spotlight 미인덱싱 시
        //   스크린샷을 전혀 찾지 못했다. 앱이 지원하는 6개 언어의 기본 파일명을 모두 처리.
        let markers = [
            "screenshot", "screen shot",     // en
            "스크린샷",                        // ko
            "スクリーンショット",                // ja
            "bildschirmfoto",                // de
            "captura de pantalla",           // es
            "capture d'écran", "capture d’écran" // fr (직선/곡선 아포스트로피 모두)
        ]
        return markers.contains { name.hasPrefix($0) || name.contains($0) }
    }

    // MARK: - 흐릿함 점수 (라플라시안 분산)

    /// 작은 그레이스케일 썸네일에 라플라시안(4-이웃) 필터를 적용해 분산을 계산.
    /// 분산이 낮을수록 경계(엣지)가 적어 흐릿함을 의미합니다. 실패 시 nil.
    nonisolated private static func blurVariance(url: URL, maxPixel: CGFloat = 120) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let width = cg.width
        let height = cg.height
        guard width > 2, height > 2 else { return nil }

        // 8비트 그레이스케일 비트맵으로 렌더
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var buffer = [UInt8](repeating: 0, count: width * height)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        // 라플라시안 분산: lap = 4*center - 상하좌우
        var sum = 0.0
        var sumSq = 0.0
        var count = 0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                let lap = 4.0 * Double(buffer[i])
                    - Double(buffer[i - 1]) - Double(buffer[i + 1])
                    - Double(buffer[i - width]) - Double(buffer[i + width])
                sum += lap
                sumSq += lap * lap
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let mean = sum / Double(count)
        return sumSq / Double(count) - mean * mean
    }

    // MARK: - 유사 사진 해시 (dHash) + 클러스터링

    /// 9×8 그레이스케일로 줄여 가로 인접 픽셀 비교로 64비트 difference hash 생성.
    nonisolated private static func differenceHash(url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let w = 9, h = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var buffer = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<h {
            let row = y * w
            for x in 0..<(w - 1) {
                if buffer[row + x] > buffer[row + x + 1] {
                    hash |= (UInt64(1) << bit)
                }
                bit += 1
            }
        }
        return hash   // 8행 × 8비교 = 64비트
    }

    /// 기존 테스트와 해시 전용 호출부를 위한 편의 오버로드입니다.
    nonisolated static func clusterByHash(_ hashes: [(String, UInt64)], threshold: Int) -> [[String]] {
        clusterByHash(
            hashes.map {
                SimilarHashCandidate(id: $0.0, hash: $0.1, pixelWidth: 1, pixelHeight: 1)
            },
            threshold: threshold
        )
    }

    /// 완전 연결 조건으로 유사 사진을 묶습니다.
    /// 입력을 해시와 ID 순으로 먼저 정렬해 병렬 해시 계산 완료 순서와 관계없이
    /// 항상 같은 결과를 만들며, 그룹의 모든 구성원과 해밍 거리·비율 조건을 만족해야 합니다.
    nonisolated static func clusterByHash(
        _ hashes: [SimilarHashCandidate],
        threshold: Int,
        aspectRatioTolerance: Double = 0.05
    ) -> [[String]] {
        let ordered = hashes.sorted {
            if $0.hash == $1.hash { return $0.id < $1.id }
            return $0.hash < $1.hash
        }
        var groups: [[SimilarHashCandidate]] = []

        for candidate in ordered {
            if Task.isCancelled { break }

            var bestIndex: Int?
            var bestDistance = Int.max

            for groupIndex in groups.indices {
                var worstDistance = 0
                var fits = true

                for member in groups[groupIndex] {
                    guard hasCompatibleAspectRatio(candidate, member, tolerance: aspectRatioTolerance) else {
                        fits = false
                        break
                    }

                    let distance = (member.hash ^ candidate.hash).nonzeroBitCount
                    if distance > threshold {
                        fits = false
                        break
                    }
                    worstDistance = max(worstDistance, distance)
                }

                if fits && worstDistance < bestDistance {
                    bestDistance = worstDistance
                    bestIndex = groupIndex
                }
            }

            if let bestIndex {
                groups[bestIndex].append(candidate)
            } else {
                groups.append([candidate])
            }
        }

        return groups
            .filter { $0.count >= 2 }
            .map { $0.map(\.id).sorted() }
            .sorted { ($0.first ?? "") < ($1.first ?? "") }
    }

    nonisolated static func hasCompatibleAspectRatio(
        _ lhs: SimilarHashCandidate,
        _ rhs: SimilarHashCandidate,
        tolerance: Double = 0.05
    ) -> Bool {
        guard lhs.pixelWidth > 0, lhs.pixelHeight > 0,
              rhs.pixelWidth > 0, rhs.pixelHeight > 0 else {
            // 비율을 확인할 수 없는 사진은 자동 유사 그룹에서 제외합니다.
            return false
        }

        let lhsLandscape = lhs.pixelWidth >= lhs.pixelHeight
        let rhsLandscape = rhs.pixelWidth >= rhs.pixelHeight
        guard lhsLandscape == rhsLandscape else { return false }

        let lhsRatio = Double(lhs.pixelWidth) / Double(lhs.pixelHeight)
        let rhsRatio = Double(rhs.pixelWidth) / Double(rhs.pixelHeight)
        let relativeDifference = abs(lhsRatio - rhsRatio) / max(lhsRatio, rhsRatio)
        return relativeDifference <= max(tolerance, 0)
    }


    /// UTType 우선 판별, 실패 시 확장자 폴백.
    nonisolated private static func isImageFile(url: URL, typeIdentifier: String?) -> Bool {
        if let typeIdentifier, let type = UTType(typeIdentifier), type.conforms(to: .image) {
            return true
        }
        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = [
            "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif",
            "bmp", "webp", "raw", "cr2", "nef", "arw", "dng"
        ]
        return imageExts.contains(ext)
    }

}
