//
//  LargeFilesViewModel.swift
//  TriClean
//
//  대용량 파일 화면의 스캔·정렬·삭제 로직.
//
//  ⚠️ 이 파일은 `LargeFilesView`에 들어 있던 약 500줄의 로직을 옮긴 것이다.
//     뷰 struct가 상태를 들고 있으면 `ContentView`의 `switch selection`으로
//     탭을 벗어나는 순간 뷰가 파괴되면서 다음 문제가 생긴다.
//      - `@State`로 잡고 있던 `scanTask`가 사라지지만 Task는 계속 돌아
//        보안 스코프를 연 채 남는다(좀비 작업).
//      - 스캔 결과·선택 폴더·무시 목록이 탭 전환마다 전부 사라진다.
//     다른 스캐너(Junk/Duplicate/Apps/Photos)와 동일하게 앱 레벨에서 한 번만
//     생성해 `EnvironmentObject`로 주입한다.
//

import Foundation
import AppKit
import Combine

@MainActor
final class LargeFilesViewModel: ObservableObject {

    // MARK: - 정렬 모드

    /// 이 프로젝트는 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`라 명시하지 않으면
    /// 타입과 합성 conformance까지 MainActor로 추론된다.
    nonisolated enum TopFolderSort: String, CaseIterable, Identifiable, Sendable {
        case discovered
        case name
        case size

        var id: String { rawValue }

        var title: String {
            switch self {
            case .discovered: return "storage.scan.sort.default".localized
            case .name: return "storage.scan.sort.name".localized
            case .size: return "storage.scan.sort.size".localized
            }
        }
    }

    private enum ScanTrigger {
        case manual
        case auto
    }

    // MARK: - Published

    @Published var minFolderSizeMB: Double = 200
    @Published private(set) var selectedFolderURL: URL? = nil
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var isAutoUpdating: Bool = false
    @Published private(set) var isDeleting: Bool = false
    @Published private(set) var scanMessage: String = "storage.scan.default_msg".localized
    @Published private(set) var folderResults: [FolderInfo] = []
    @Published private(set) var discoveredResults: [FolderInfo] = []

    @Published var tableSelection = Set<FolderInfo.ID>()
    @Published var topFolderSort: TopFolderSort = .discovered

    @Published private(set) var deleteTargets: [FolderInfo] = []
    @Published var showingDeleteAlert = false

    // MARK: - 내부 상태

    private var ignoredFolderURLs: Set<URL> = []
    private var scanTask: Task<Void, Never>? = nil
    private var activeScanID = UUID()

    /// 화면이 보이는 동안만 슬라이더 변경에 반응하기 위한 기준값.
    ///
    /// `.task(id:)`는 뷰가 **나타날 때도** 한 번 실행된다. 진입 시점의 값을 기준으로
    /// 잡아두면 "탭에 들어간 것만으로 수 분짜리 전체 순회가 시작되는" 상황을 막으면서,
    /// 화면에 머무는 동안의 실제 슬라이더 조작은 그대로 잡아낼 수 있다.
    /// 화면을 벗어나면 nil로 되돌려 자동 재스캔을 완전히 끈다.
    private var autoScanBaseline: Double? = nil

    /// 결과 목록이 표시되는 동안 유지하는 보안 스코프 접근.
    /// 스캔이 끝나도 닫지 않는다 — Finder 열기·삭제에서 다시 필요하다.
    private var folderAccessToken: SecurityScopedAccessToken? = nil

    private let bookmarks = SecurityScopedBookmarkStore.shared

    // MARK: - Computed

    var rootResultCount: Int { folderResults.lazy.filter { $0.depth == 0 }.count }
    var childResultCount: Int { folderResults.lazy.filter { $0.depth > 0 }.count }

    var hasResults: Bool { !folderResults.isEmpty }

    var selectedFolderDisplayName: String {
        guard let selectedFolderURL else { return "storage.status.folder_none".localized }
        return selectedFolderURL.lastPathComponent.isEmpty
            ? selectedFolderURL.path
            : selectedFolderURL.lastPathComponent
    }

    var minFolderSizeDisplay: String {
        "storage.min_size.display".localized(with: Int(minFolderSizeMB))
    }

    var scanButtonBusyText: String {
        isAutoUpdating
            ? "storage.scan.updating".localized
            : "storage.scan.scanning".localized
    }

    var canScan: Bool { !isScanning && !isDeleting }

    // MARK: - 수명주기

    init() {
        if let restored = bookmarks.resolveURL(for: .largeFilesScanFolder) {
            selectedFolderURL = restored
        }
    }

    /// 설정·온보딩의 공통 권한 설정(`FolderAccessSetup`)에서 새로 받은 폴더를 반영한다.
    /// 사용자가 이 화면에서 이미 골라둔 폴더나 진행 중인 작업은 건드리지 않는다.
    func reloadSharedFolderAccess() {
        guard selectedFolderURL == nil, canScan else { return }
        selectedFolderURL = bookmarks.resolveURL(for: .largeFilesScanFolder)
    }

    /// 화면 진입 시점의 최소 크기를 자동 재스캔 기준값으로 고정한다.
    func onAppear() {
        autoScanBaseline = minFolderSizeMB
    }

    /// 화면을 벗어날 때 진행 중인 스캔을 반드시 정리한다.
    /// (`ContentView`가 탭 전환 시 뷰를 파괴하므로 여기서 멈추지 않으면 계속 돈다.)
    func onDisappear() {
        autoScanBaseline = nil
        cancelActiveScan()
    }

    // MARK: - 폴더 선택

    func selectFolderAndScan() {
        guard canScan else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = selectedFolderURL

        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }

            Task { @MainActor in
                // `panel.begin`은 비모달이라 패널이 떠 있는 동안 메인 창에서 삭제를 시작할 수 있다.
                // 삭제 중에 폴더를 바꾸면 이전 결과가 새 폴더 이름 아래 남고(스코프는 닫힘),
                // 이후 삭제는 새 폴더 기준으로 검증되어 전부 실패한다. 삭제가 끝난 뒤 다시 고르게 한다.
                guard !self.isDeleting else {
                    self.scanMessage = "junk.progress.wait".localized
                    return
                }

                // 다음 실행에서도 같은 폴더를 다시 고르지 않도록 북마크를 저장한다.
                self.bookmarks.trySave(url: url, for: .largeFilesScanFolder)

                // 이전 폴더의 보안 스코프 접근을 반드시 닫는다(누수 방지).
                self.folderAccessToken?.stop()
                self.folderAccessToken = nil

                self.selectedFolderURL = url
                self.ignoredFolderURLs = []
                self.tableSelection.removeAll()
                self.runScan(for: url, minSizeMB: self.minFolderSizeMB, trigger: .manual)
            }
        }
    }

    // MARK: - 스캔

    /// 최소 크기 슬라이더 변경에 따른 자동 재스캔.
    /// 디바운스는 호출부(`.task(id:)`)가 담당하고, 여기서는 중복 실행만 막는다.
    ///
    /// ⚠️ `.task(id:)`는 뷰가 나타날 때도 한 번 실행된다. 북마크로 폴더가 복원된
    ///   상태에서 조건이 느슨하면 **탭에 들어가는 것만으로** 수 분짜리 전체 순회가
    ///   시작된다. 그래서 "완료한 스캔이 있는지"가 아니라 **"화면에 머무는 동안
    ///   사용자가 슬라이더를 실제로 움직였는지"**(`autoScanBaseline`)로 판정한다.
    ///   완료 여부를 기준으로 삼으면 첫 스캔을 취소했을 때 슬라이더가 영영
    ///   반응하지 않고, 값을 바꾼 뒤 탭을 나갔다 오면 진입만으로 스캔이 시작된다.
    func autoRescanIfNeeded(minSizeMB: Double) {
        // 화면에 들어왔을 때의 값 또는 마지막으로 처리한 슬라이더 값과 같으면
        // 새 변경이 아니다. `.task(id:)`의 최초 실행도 여기서 걸러진다.
        guard let baseline = autoScanBaseline, baseline != minSizeMB else { return }

        // 삭제 중 변경은 처리 완료 후 `confirmDelete()`가 다시 호출하므로
        // 여기서 기준값을 갱신하면 안 된다. 그래야 변경 사실이 보존된다.
        guard !isDeleting else { return }

        // 폴더가 없을 때는 스캔할 수 없지만, 이번 UI 변경은 처리된 것으로 본다.
        guard let url = selectedFolderURL else {
            autoScanBaseline = minSizeMB
            return
        }

        // 스캔 시작 직전에 갱신한다. 진행 중인 자동 스캔이 일부 결과를 표시한 뒤
        // 사용자가 이전 값으로 되돌린 경우에도 반드시 새 스캔이 시작되어
        // 화면 조건과 실제 결과가 다시 일치한다.
        autoScanBaseline = minSizeMB
        runScan(for: url, minSizeMB: minSizeMB, trigger: .auto)
    }

    /// 진행 중인 스캔을 멈추고 화면 상태를 확정한다.
    ///
    /// `activeScanID`를 함께 갱신하는 것이 핵심이다. 이것을 빼먹으면 취소된 Task의
    /// 완료 블록이 세대 검사를 통과해 `scanMessage`를 나중에 덮어쓴다
    /// (삭제 진행 메시지가 "취소됨"으로 바뀌는 원인).
    private func stopScan(message: String?) {
        scanTask?.cancel()
        scanTask = nil
        activeScanID = UUID()
        isScanning = false
        isAutoUpdating = false
        if let message { scanMessage = message }
        // 스캔 중에는 정렬 변경을 미뤄두므로(LargeFilesView의 onValueChange), 스캔을 멈출 때
        // 현재 정렬을 적용하지 않으면 선택기와 목록 순서가 어긋난 채 남는다.
        applyTopFolderSortFromDiscovered()
    }

    func cancelActiveScan() {
        guard scanTask != nil else { return }
        stopScan(message: "storage.msg.canceled".localized)
    }

    private func runScan(for url: URL, minSizeMB: Double, trigger: ScanTrigger) {
        // ⚠️ 삭제 중에는 절대 스캔을 시작하지 않는다.
        //    삭제 Task가 `folderResults`를 지우는 동안 스캔 Task가 append하면
        //    이미 휴지통으로 간 항목이 목록에 되살아난다.
        guard !isDeleting else { return }

        scanTask?.cancel()

        let scanID = UUID()
        activeScanID = scanID

        let root = url.standardizedFileURL
        let isAuto = (trigger == .auto)

        // 결과 표시 중 Finder 열기·삭제에 필요한 접근을 유지한다.
        // 스코프는 북마크에서 복원한 **원본 URL**로 시작해야 한다.
        if folderAccessToken == nil {
            guard let token = SecurityScopedAccessToken(url: url) else {
                // 권한이 만료된 상태에서 이전 결과를 그대로 두면 사용자가 현재 폴더의
                // 결과로 오인할 수 있으므로, 스캔 실패와 함께 stale 결과도 정리한다.
                scanTask = nil
                tableSelection.removeAll()
                folderResults = []
                discoveredResults = []
                isAutoUpdating = false
                isScanning = false
                scanMessage = "storage.msg.access_denied".localized
                return
            }
            folderAccessToken = token
        }

        // 삭제한 경로에 새 파일·폴더가 다시 생겼다면 다른 항목이므로 더 이상 숨기지 않는다.
        // 존재 여부는 보안 스코프를 연 뒤에 확인해야 샌드박스 거부로 오판하지 않는다.
        ignoredFolderURLs = ignoredFolderURLs.filter { !FileManager.default.fileExists(atPath: $0.path) }
        let ignoredSnapshot = ignoredFolderURLs

        isAutoUpdating = isAuto
        isScanning = true
        // 자동 재스캔은 사용자가 고른 항목을 이유 없이 풀지 않는다.
        if trigger == .manual {
            tableSelection.removeAll()
        }

        switch trigger {
        case .manual:
            scanMessage = "storage.msg.manual".localized(with: url.lastPathComponent)
        case .auto:
            scanMessage = "storage.msg.auto".localized
        }

        if trigger == .manual {
            folderResults = []
            discoveredResults = []
        }

        scanTask = Task(priority: .userInitiated) { [weak self] in
            var didReplace = (trigger == .manual)

            let stream = Self.scanStructuredItemsBatches(
                of: root,
                minSizeMB: minSizeMB,
                ignoredFolderURLs: ignoredSnapshot,
                batchSize: 220
            )

            for await batch in stream {
                if Task.isCancelled { break }

                let shouldReplace = !didReplace
                await MainActor.run {
                    guard let self, self.activeScanID == scanID else { return }

                    if shouldReplace {
                        self.folderResults = batch
                        self.discoveredResults = batch
                    } else {
                        self.folderResults.append(contentsOf: batch)
                        self.discoveredResults.append(contentsOf: batch)
                    }
                }

                didReplace = true
            }

            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self, self.activeScanID == scanID else { return }

                self.isScanning = false
                self.isAutoUpdating = false
                self.scanTask = nil

                if cancelled {
                    self.scanMessage = "storage.msg.canceled".localized
                    return
                }

                if !didReplace {
                    self.folderResults = []
                    self.discoveredResults = []
                }

                self.applyTopFolderSortFromDiscovered()

                let results = self.folderResults
                let folderCount = results.filter { $0.isDirectory && $0.depth == 0 }.count
                let fileCount = results.filter { !$0.isDirectory }.count

                if results.isEmpty {
                    self.scanMessage = "storage.msg.no_items".localized(with: root.lastPathComponent)
                } else {
                    self.scanMessage = "storage.msg.completed".localized(
                        with: root.lastPathComponent, folderCount, fileCount
                    )
                }
            }
        }
    }

    // MARK: - 정렬

    func applyTopFolderSortFromDiscovered() {
        switch topFolderSort {
        case .discovered:
            folderResults = discoveredResults
        case .name, .size:
            folderResults = Self.sortedTopFolderGroups(in: discoveredResults, by: topFolderSort)
        }
    }

    nonisolated private static func sortedTopFolderGroups(
        in results: [FolderInfo],
        by mode: TopFolderSort
    ) -> [FolderInfo] {
        guard mode != .discovered else { return results }

        var rootItems: [FolderInfo] = []
        rootItems.reserveCapacity(64)

        var topFolders: [FolderInfo] = []
        topFolders.reserveCapacity(64)

        var childrenByParent: [URL: [FolderInfo]] = [:]
        childrenByParent.reserveCapacity(64)

        for item in results {
            if item.depth == 0, item.parentURL == nil, item.isDirectory {
                topFolders.append(item)
            } else if item.depth == 0, item.parentURL == nil, !item.isDirectory {
                rootItems.append(item)
            } else if let parent = item.parentURL {
                childrenByParent[parent.standardizedFileURL, default: []].append(item)
            } else {
                rootItems.append(item)
            }
        }

        switch mode {
        case .name:
            topFolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            topFolders.sort {
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .discovered:
            break
        }

        var output: [FolderInfo] = []
        output.reserveCapacity(results.count)

        var included = Set<FolderInfo.ID>()
        included.reserveCapacity(results.count)

        output.append(contentsOf: rootItems)
        for i in rootItems { included.insert(i.id) }

        for folder in topFolders {
            output.append(folder)
            included.insert(folder.id)

            if let children = childrenByParent[folder.url.standardizedFileURL] {
                output.append(contentsOf: children)
                for c in children { included.insert(c.id) }
            }
        }

        if included.count != results.count {
            for item in results where !included.contains(item.id) {
                output.append(item)
            }
        }

        return output
    }

    // MARK: - 파일 순회 (백그라운드)

    /// ⚠️ **할당 크기**를 쓴다(논리 크기가 아니다). 이 선택이 두 가지를 동시에 해결한다.
    ///   - 폴더 합계가 실제 디스크 점유와 일치한다.
    ///   - iCloud "저장 공간 최적화" 등으로 로컬에 내용이 없는 자리표시자 파일은 0바이트로
    ///     잡혀 최소 크기 필터에 걸러진다. 따라서 이 화면은 클라우드 파일을 건드리지 않는다.
    ///     (논리 크기로 바꾸면 자리표시자가 목록에 올라오고, 삭제 시 다운로드가 유발된다.
    ///      중복 탐색이 실제로 그 문제를 겪었다 — `CloudFileStatus` 참고.)
    nonisolated private static func fileSize(from values: URLResourceValues) -> Int {
        values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
    }

    nonisolated private static func scanStructuredItemsBatches(
        of root: URL,
        minSizeMB: Double,
        ignoredFolderURLs: Set<URL>,
        batchSize: Int
    ) -> AsyncStream<[FolderInfo]> {
        AsyncStream { continuation in
            let producer = Task.detached(priority: .utility) {
                let fm = FileManager.default
                let rootStd = root.standardizedFileURL

                let directKeys: [URLResourceKey] = [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
                    .fileSizeKey,
                    .isPackageKey
                ]

                guard let directItems = try? fm.contentsOfDirectory(
                    at: rootStd,
                    includingPropertiesForKeys: directKeys,
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.finish()
                    return
                }

                var topFolders: [URL] = []
                // 스캔 루트 바로 아래의 패키지(.photoslibrary, .app, .fcpbundle 등).
                // 하위 탐색의 `packagePrefixes`는 더 깊은 곳에서 발견한 패키지만 다루므로,
                // 최상위 패키지는 따로 기억해 내부 파일을 개별 삭제 항목으로 노출하지 않는다.
                var topPackages = Set<URL>()
                var rootFiles: [FolderInfo] = []
                rootFiles.reserveCapacity(64)

                for raw in directItems {
                    if Task.isCancelled { break }

                    // 대량 순회는 autoreleased 객체가 쌓이므로 항목마다 풀을 비운다.
                    autoreleasepool {
                        let url = raw.standardizedFileURL
                        if ignoredFolderURLs.contains(url) { return }

                        guard let values = try? url.resourceValues(forKeys: Set(directKeys)) else { return }

                        if values.isDirectory == true {
                            topFolders.append(url)
                            if values.isPackage == true { topPackages.insert(url) }
                            return
                        }

                        if values.isRegularFile == true {
                            let size = Int64(Self.fileSize(from: values))
                            let sizeMB = Double(size) / 1024.0 / 1024.0
                            if sizeMB >= minSizeMB {
                                rootFiles.append(
                                    FolderInfo(url: url, sizeBytes: size, isDirectory: false, depth: 0, parentURL: nil)
                                )
                            }
                        }
                    }
                }

                rootFiles.sort { $0.sizeBytes > $1.sizeBytes }

                var idx = 0
                while idx < rootFiles.count {
                    if Task.isCancelled { break }

                    let end = min(idx + max(batchSize, 1), rootFiles.count)
                    continuation.yield(Array(rootFiles[idx..<end]))
                    idx = end
                    await Task.yield()
                }

                let scanKeys: [URLResourceKey] = [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
                    .fileSizeKey,
                    .isPackageKey
                ]

                for folderURL in topFolders {
                    if Task.isCancelled { break }

                    let folder = folderURL.standardizedFileURL
                    if ignoredFolderURLs.contains(folder) { continue }

                    guard let enumerator = fm.enumerator(
                        at: folder,
                        includingPropertiesForKeys: scanKeys,
                        options: [.skipsHiddenFiles],
                        errorHandler: { _, _ in true }
                    ) else {
                        continue
                    }

                    var total: Int64 = 0
                    var children: [FolderInfo] = []
                    children.reserveCapacity(64)

                    var packagePrefixes: [String] = []
                    packagePrefixes.reserveCapacity(8)

                    let minBytes = Int64(minSizeMB * 1024.0 * 1024.0)
                    let isPackageRoot = topPackages.contains(folder)

                    // ⚠️ `for ... in enumerator`를 쓸 수 없다. 일반 Sequence 순회는 async에서도
                    //    되지만, `FileManager.DirectoryEnumerator`의 `makeIterator()`는
                    //    비동기 컨텍스트에서 사용 불가로 표시되어 있다(Swift 6에서는 에러).
                    //    한편 `while let x = enumerator.nextObject() as? URL` 형태는 URL이 아닌
                    //    객체가 나오는 순간 순회를 조용히 끝내버려 스캔이 잘린다.
                    //    따라서 객체를 먼저 꺼낸 뒤 캐스팅 실패한 항목만 건너뛴다.
                    while let rawObject = enumerator.nextObject() {
                        if Task.isCancelled { break }

                        autoreleasepool {
                            guard let rawURL = rawObject as? URL else { return }
                            let url = rawURL.standardizedFileURL

                            if ignoredFolderURLs.contains(url) {
                                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                                    enumerator.skipDescendants()
                                }
                                return
                            }

                            guard let values = try? url.resourceValues(forKeys: Set(scanKeys)) else { return }

                            if values.isDirectory == true && values.isPackage == true {
                                let prefix = url.path.hasSuffix("/") ? url.path : (url.path + "/")
                                packagePrefixes.append(prefix)
                                return
                            }

                            guard values.isRegularFile == true else { return }

                            let size = Int64(Self.fileSize(from: values))
                            total += size

                            guard size >= minBytes, !isPackageRoot else { return }

                            let path = url.path
                            for prefix in packagePrefixes where path.hasPrefix(prefix) {
                                return
                            }

                            children.append(
                                FolderInfo(url: url, sizeBytes: size, isDirectory: false, depth: 1, parentURL: folder)
                            )
                        }
                    }

                    if Task.isCancelled { break }
                    guard total >= minBytes else { continue }

                    continuation.yield([
                        FolderInfo(url: folder, sizeBytes: total, isDirectory: true, depth: 0, parentURL: nil)
                    ])
                    await Task.yield()

                    if !children.isEmpty {
                        children.sort { $0.sizeBytes > $1.sizeBytes }

                        var j = 0
                        while j < children.count {
                            if Task.isCancelled { break }

                            let end = min(j + max(batchSize, 1), children.count)
                            continuation.yield(Array(children[j..<end]))
                            j = end
                            await Task.yield()
                        }
                    }
                }

                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    // MARK: - Finder

    func openInFinder(_ item: FolderInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - 삭제

    nonisolated private struct LargeDeleteOutcome: Sendable {
        let succeededURLs: Set<URL>
        let rejectedCount: Int
    }

    func requestDelete(_ item: FolderInfo) {
        guard !isScanning, !isDeleting else { return }
        deleteTargets = [item]
        showingDeleteAlert = true
    }

    func requestDeleteSelected() {
        guard !isScanning, !isDeleting else { return }
        let selected = folderResults.filter { tableSelection.contains($0.id) }
        guard !selected.isEmpty else { return }
        deleteTargets = selected
        showingDeleteAlert = true
    }

    func cancelDeleteRequest() {
        deleteTargets = []
    }

    func confirmDelete() {
        // 뷰에서 이미 게이팅하지만, 삭제 실행 직전 마지막 방어선을 유지한다
        // (다른 스캐너 ViewModel과 동일한 패턴).
        guard StoreManager.shared.isPurchased else {
            deleteTargets = []
            return
        }
        let candidates = Self.normalizedDeleteTargets(deleteTargets)
        guard !candidates.isEmpty else { return }
        guard !isDeleting else { return }

        // ⚠️ 보안 스코프는 북마크에서 복원한 **원본 URL**로 시작해야 한다.
        //    경로 경계 검증에만 standardized 형태를 쓴다.
        guard let scopeURL = selectedFolderURL else {
            deleteTargets = []
            scanMessage = "storage.msg.trash_failed".localized
            return
        }
        let validationScope = scopeURL.standardizedFileURL

        // 삭제와 스캔이 같은 배열을 동시에 건드리지 않도록 진행 중인 스캔을 먼저 멈춘다.
        // 메시지는 여기서 덮어쓰지 않고 바로 아래 삭제 진행 문구로 설정한다.
        stopScan(message: nil)

        isDeleting = true
        scanMessage = "storage.msg.trash_moving".localized(with: candidates.count)

        let hasPersistentAccess = folderAccessToken != nil

        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                await Self.moveToTrash(
                    candidates,
                    securityScopedBy: scopeURL,
                    validationScope: validationScope,
                    hasPersistentAccess: hasPersistentAccess
                )
            }.value

            guard let self else { return }

            let succeededURLs = outcome.succeededURLs
            let acceptedCount = max(0, candidates.count - outcome.rejectedCount)
            let failedCount = outcome.rejectedCount + max(0, acceptedCount - succeededURLs.count)

            self.isDeleting = false
            self.deleteTargets = []

            guard !succeededURLs.isEmpty else {
                self.scanMessage = "storage.msg.trash_failed".localized
                return
            }

            self.ignoredFolderURLs.formUnion(succeededURLs)

            let isRemoved: (FolderInfo) -> Bool = { info in
                let u = info.url.standardizedFileURL
                if succeededURLs.contains(u) { return true }
                if let p = info.parentURL?.standardizedFileURL, succeededURLs.contains(p) { return true }
                return false
            }

            // 하위 파일만 지운 경우 상위 폴더 행의 크기도 줄여야 목록·트리맵·정렬이 맞는다.
            var removedBytesByParent: [URL: Int64] = [:]
            for info in self.discoveredResults where succeededURLs.contains(info.url.standardizedFileURL) {
                guard let parent = info.parentURL?.standardizedFileURL, !succeededURLs.contains(parent) else { continue }
                removedBytesByParent[parent, default: 0] += info.sizeBytes
            }
            let shrinkParent: (FolderInfo) -> FolderInfo = { info in
                guard info.isDirectory,
                      let removed = removedBytesByParent[info.url.standardizedFileURL] else { return info }
                return FolderInfo(
                    url: info.url,
                    sizeBytes: max(0, info.sizeBytes - removed),
                    isDirectory: info.isDirectory,
                    depth: info.depth,
                    parentURL: info.parentURL,
                    fileIdentity: info.fileIdentity
                )
            }

            self.discoveredResults.removeAll(where: isRemoved)
            if !removedBytesByParent.isEmpty {
                self.discoveredResults = self.discoveredResults.map(shrinkParent)
            }
            // 크기가 바뀌었으므로 크기 정렬을 다시 적용한다.
            self.applyTopFolderSortFromDiscovered()

            let remainingIDs = Set(self.folderResults.map(\.id))
            self.tableSelection.formIntersection(remainingIDs)

            self.scanMessage = failedCount > 0
                ? "storage.msg.trash_partial".localized(with: succeededURLs.count, failedCount)
                : "storage.msg.trash_done".localized(with: succeededURLs.count)

            // 삭제 중에 슬라이더가 바뀌었다면 `runScan`이 거부했으므로 여기서 한 번 반영한다.
            self.autoRescanIfNeeded(minSizeMB: self.minFolderSizeMB)
        }
    }

    nonisolated private static func normalizedDeleteTargets(_ items: [FolderInfo]) -> [FolderInfo] {
        let sorted = items.sorted { lhs, rhs in
            let lhsPath = DeletionSafety.resolvedPath(for: lhs.url)
            let rhsPath = DeletionSafety.resolvedPath(for: rhs.url)
            if lhsPath.count == rhsPath.count { return lhsPath < rhsPath }
            return lhsPath.count < rhsPath.count
        }

        var result: [FolderInfo] = []
        for item in sorted {
            let isCoveredByParent = result.contains { parent in
                parent.isDirectory && DeletionSafety.isContained(item.url, inScope: parent.url)
            }
            if !isCoveredByParent {
                result.append(item)
            }
        }
        return result
    }

    nonisolated private static func moveToTrash(
        _ candidates: [FolderInfo],
        securityScopedBy securityScopedURL: URL,
        validationScope: URL,
        hasPersistentAccess: Bool
    ) async -> LargeDeleteOutcome {
        let token = SecurityScopedAccessToken(url: securityScopedURL)
        defer { token?.stop() }

        // 결과 표시용 장기 토큰이 이미 열려 있으면 중첩 start 실패는 문제가 아니다.
        guard token != nil || hasPersistentAccess else {
            return LargeDeleteOutcome(succeededURLs: [], rejectedCount: candidates.count)
        }

        // 사용자가 선택한 스캔 루트의 하위 항목만 삭제할 수 있습니다.
        // 루트 자체, 형제 경로, 심볼릭 링크로 빠져나간 경로는 모두 제외합니다.
        // 폴더는 스캔~삭제 사이에 내부 파일이 바뀌면 크기·수정 시각이 달라진다.
        // 대용량 폴더 스캔은 수 분이 걸리므로 엄격 비교를 유지하면 활성 폴더가
        // 이유 없이 제외된다. device·inode·항목 유형은 여전히 일치해야 하므로
        // 같은 경로가 다른 폴더로 교체된 경우는 계속 거부된다.
        let outcome = await TrashService.sanitizeAndMoveToTrash(
            candidates,
            scopes: [.descendants(of: validationScope)],
            url: \.url,
            identity: \.fileIdentity,
            allowsDirectoryContentChanges: { $0.isDirectory },
            logCategory: "LargeFiles"
        )

        return LargeDeleteOutcome(
            succeededURLs: Set(outcome.succeeded.map { $0.url.standardizedFileURL }),
            rejectedCount: outcome.excludedCount
        )
    }
}
