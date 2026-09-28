//
//  StorageViewModel.swift
//  TriClean
//
//  StorageView가 View의 @State에 직접 들고 있던 디스크/폴더 스캔 로직을
//  다른 모듈(Junk/Duplicate/Photos/Apps)과 동일한 ViewModel 패턴으로 옮긴 것.
//
//  이관하면서 함께 해결한 문제:
//  - DispatchQueue.global + DispatchQueue.main 조합이라 스캔 취소가 불가능했다.
//    → Task.detached + withTaskCancellationHandler로 교체하고 Task 핸들을 보관한다.
//  - 세대 번호가 없어 폴더를 바꾸면 늦게 끝난 이전 스캔이 새 결과를 덮어썼다.
//    → scanGeneration으로 stale 결과를 차단한다.
//  - 보안 스코프 북마크를 자체 저장소(StorageDiskScopeBookmarks)로 따로 관리했다.
//    → 앱 공용 SecurityScopedBookmarkStore로 통합했다(키 문자열은 그대로 유지).
//

import Foundation
import Combine
import AppKit

@MainActor
final class StorageViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var diskInfo: DiskInfo? = nil

    @Published private(set) var homeScopeURL: URL? = nil
    @Published private(set) var appsScopeURLs: [URL] = []

    @Published private(set) var homeFolderBytes: Int64? = nil
    @Published private(set) var appsFolderBytes: Int64? = nil

    @Published private(set) var isHomeScanning: Bool = false
    @Published private(set) var isAppsScanning: Bool = false

    // MARK: - Computed

    var isHomeSelected: Bool { homeScopeURL != nil }
    var isAppsSelected: Bool { !appsScopeURLs.isEmpty }
    var isDetailScanning: Bool { isHomeScanning || isAppsScanning }

    /// 범례에 표시할 Applications 스코프 경로 목록
    var appsScopePathDescription: String {
        appsScopeURLs.map { $0.path }.joined(separator: " · ")
    }

    // MARK: - 작업 핸들 / 세대 번호

    /// 다른 스캐너 ViewModel과 같은 규약: Task 핸들을 보관해 취소 가능하게 하고,
    /// 세대 번호로 늦게 끝난 이전 스캔이 최신 상태를 덮어쓰지 않게 막는다.
    private var homeScanTask: Task<Void, Never>? = nil
    private var appsScanTask: Task<Void, Never>? = nil
    private var homeScanGeneration: UInt = 0
    private var appsScanGeneration: UInt = 0

    private let bookmarks = SecurityScopedBookmarkStore.shared

    // MARK: - Init

    init() {
        homeScopeURL = bookmarks.resolveURL(for: .storageHomeFolder)
        appsScopeURLs = bookmarks.resolveURLs(for: .storageApplicationsFolders)
    }

    // ⚠️ deinit은 두지 않는다.
    //   @MainActor 클래스의 deinit은 nonisolated라 격리된 Task 프로퍼티에 접근하면
    //   Swift 6 경고가 난다(StoreManager에서 같은 이유로 제거한 전례).
    //   진행 중인 스캔은 `onDisappear()`에서 명시적으로 취소한다.

    // MARK: - 화면 진입 / 이탈

    /// 화면이 나타날 때 호출. 권한(선택)이 있는 스코프만 보수적으로 계산한다.
    func onAppear() {
        loadDiskInfo()

        if isHomeSelected { scanHomeFolder() }
        if isAppsSelected { scanApplicationsFolder() }
    }

    /// 화면을 벗어나면 진행 중인 폴더 순회를 중단한다.
    /// (홈 폴더 전체 순회는 수 분이 걸릴 수 있어 방치하면 디스크 I/O가 계속된다.)
    func onDisappear() {
        cancelHomeScan()
        cancelAppsScan()
    }

    // MARK: - Disk Info

    /// "/"보다는 현재 사용자 볼륨 기준이 UI(설정/파인더)와 더 일관적인 경우가 많다.
    func loadDiskInfo() {
        let volumeURL = FileManager.default.homeDirectoryForCurrentUser

        guard
            let values = try? volumeURL.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ]),
            let total = values.volumeTotalCapacity
        else {
            diskInfo = nil
            return
        }

        let free: Int64 =
            values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)

        let totalBytes = Int64(total)
        let freeBytes = max(Int64(0), min(free, totalBytes))

        diskInfo = DiskInfo(
            name: values.volumeName ?? "Macintosh HD",
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            usedBytes: max(Int64(0), totalBytes - freeBytes)
        )
    }

    // MARK: - 폴더 크기 스캔

    func scanHomeFolder() {
        guard let homeURL = homeScopeURL else {
            cancelHomeScan()
            homeFolderBytes = nil
            return
        }

        homeScanTask?.cancel()
        homeScanGeneration &+= 1
        let generation = homeScanGeneration

        isHomeScanning = true

        homeScanTask = Task { [weak self] in
            let size = await Self.folderSize(of: [homeURL])

            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard generation == self.homeScanGeneration else { return }

            self.homeFolderBytes = size
            self.isHomeScanning = false
            self.homeScanTask = nil
        }
    }

    func scanApplicationsFolder() {
        guard !appsScopeURLs.isEmpty else {
            cancelAppsScan()
            appsFolderBytes = nil
            return
        }

        appsScanTask?.cancel()
        appsScanGeneration &+= 1
        let generation = appsScanGeneration

        let targets = appsScopeURLs
        isAppsScanning = true

        appsScanTask = Task { [weak self] in
            let size = await Self.folderSize(of: targets)

            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard generation == self.appsScanGeneration else { return }

            self.appsFolderBytes = size
            self.isAppsScanning = false
            self.appsScanTask = nil
        }
    }

    private func cancelHomeScan() {
        homeScanTask?.cancel()
        homeScanTask = nil
        homeScanGeneration &+= 1
        isHomeScanning = false
    }

    private func cancelAppsScan() {
        appsScanTask?.cancel()
        appsScanTask = nil
        appsScanGeneration &+= 1
        isAppsScanning = false
    }

    // MARK: - 스코프 선택 (사용자 선택 기반)

    func selectHomeFolderForDiskUsage() {
        let panel = NSOpenPanel()
        panel.title = "storage.scope.select_home_title".localized
        panel.message = "storage.scope.select_home_msg".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return }

        bookmarks.trySave(url: url, for: .storageHomeFolder)
        homeScopeURL = url
        homeFolderBytes = nil
        scanHomeFolder()
    }

    func selectApplicationsFoldersForDiskUsage() {
        let panel = NSOpenPanel()
        panel.title = "storage.scope.select_apps_title".localized
        panel.message = "storage.scope.select_apps_msg".localized
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        // ⚠️ 북마크 저장이 실패해도 패널이 부여한 세션 스코프로 스캔은 가능하다.
        //   따라서 사용자 선택은 항상 반영하고, 저장에 성공한 경우에만
        //   저장소의 정규화(중복 제거·경로 정렬) 결과로 교체한다.
        //   (저장 실패 시 조용히 선택이 사라지던 문제 방지)
        if bookmarks.trySaveMany(urls: urls, for: .storageApplicationsFolders) {
            let resolved = bookmarks.resolveURLs(for: .storageApplicationsFolders)
            appsScopeURLs = resolved.isEmpty ? urls : resolved
        } else {
            appsScopeURLs = urls
        }

        appsFolderBytes = nil
        scanApplicationsFolder()
    }

    func clearHomeFolderScope() {
        bookmarks.clear(.storageHomeFolder)
        cancelHomeScan()
        homeScopeURL = nil
        homeFolderBytes = nil
    }

    func clearApplicationsFoldersScope() {
        bookmarks.clear(.storageApplicationsFolders)
        cancelAppsScan()
        appsScopeURLs = []
        appsFolderBytes = nil
    }

    // MARK: - Size Utilities

    /// 여러 스코프의 합계를 백그라운드에서 계산한다.
    ///
    /// `Task.detached`는 부모 Task의 취소를 자동으로 상속하지 않으므로
    /// `withTaskCancellationHandler`로 취소를 직접 전달한다.
    private nonisolated static func folderSize(of urls: [URL]) async -> Int64 {
        let worker = Task.detached(priority: .userInitiated) { () -> Int64 in
            var total: Int64 = 0
            for url in urls {
                if Task.isCancelled { break }
                // 보안 스코프 접근은 북마크에서 복원한 원본 URL로 시작해야 한다.
                let token = SecurityScopedAccessToken(url: url)
                defer { token?.stop() }
                total &+= Self.folderSizeBytes(at: url)
            }
            return total
        }

        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func folderSizeBytes(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey
        ]

        // 숨김 항목도 디스크를 차지한다. `.skipsHiddenFiles`를 쓰면 UF_HIDDEN 플래그가 붙은
        // ~/Library와 `.Trash`·`.cache` 같은 점 폴더가 빠져, 수십 GB가 "기타"로 표시되었다.
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        let keySet = Set(keys)

        // Swift 6: DirectoryEnumerator의 for-in 순회는 async 컨텍스트에서
        // makeIterator() 이슈가 날 수 있으므로 nextObject() 기반으로 순회한다.
        while let fileURL = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let values = try? fileURL.resourceValues(forKeys: keySet) else { continue }
            guard values.isRegularFile == true else { continue }

            total &+= Int64(
                values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            )
        }

        return total
    }
}
