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
import CoreServices   // Spotlight 메타데이터(kMDItemIsScreenCapture)

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

    // 이후 단계의 카테고리 필터를 위한 자리. 1단계에서는 .all만 의미가 있습니다.
    @Published var selectedCategory: PhotoCategory = .all

    private var scanTask: Task<Void, Never>? = nil
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
    let readyCategories: [PhotoCategory] = [.all, .screenshot]

    var screenshotCount: Int { items.lazy.filter { $0.isScreenshot }.count }

    func count(for category: PhotoCategory) -> Int {
        switch category {
        case .all:        return totalCount
        case .screenshot: return screenshotCount
        case .similar, .blurry: return 0   // 이후 단계
        }
    }

    /// 선택된 카테고리에 해당하는 항목만 반환.
    var filteredItems: [PhotoItem] {
        switch selectedCategory {
        case .all:        return items
        case .screenshot: return items.filter { $0.isScreenshot }
        case .similar, .blurry: return []  // 이후 단계
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
        let panel = NSOpenPanel()
        panel.title = "photos.select_folder.title".localized
        panel.message = "photos.select_folder.message".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            saveBookmark(url: url)
            scanFolderURL = url
            items = []
            phase = .idle
            statusMessage = "photos.status.ready".localized
        }
    }

    // MARK: - 스캔

    func scan() {
        guard let folderURL = scanFolderURL else { return }
        guard !isScanning else { return }

        scanTask?.cancel()

        isScanning = true
        items = []
        progress = 0
        lastScanDate = nil
        selectedCategory = .all
        phase = .collecting
        statusMessage = "photos.status.collecting".localized

        let root = folderURL.standardizedFileURL

        // ✅ 보안 스코프: 결과가 표시되는 동안(썸네일 lazy 로딩 포함) 접근을 유지.
        //    스캔 직후 닫으면 샌드박스에서 썸네일 파일 읽기가 거부되어 모두 실패합니다.
        beginFolderAccess(root)

        // ✅ 실제 취소 가능한 detached 작업(핸들을 보관해 직접 cancel)
        let collect = Task.detached(priority: .utility) { () -> [PhotoItem] in
            // 스크린샷은 Spotlight 일괄 질의 1회로 해결(파일별 호출 제거)
            let shots = Self.screenshotPaths(in: root)
            return Self.collectImages(in: root, screenshotPaths: shots)
        }
        collectTask = collect

        scanTask = Task { [weak self] in
            let collected = await collect.value
            // 폴더 접근은 여기서 닫지 않음 — 다음 스캔/폴더 변경 시 교체됨
            guard let self else { return }

            if collect.isCancelled {
                self.items = []
                self.finishScan(cancelled: true)
            } else {
                // 큰 파일(용량 우선)이 먼저 보이도록 정렬
                self.items = collected.sorted { $0.sizeBytes > $1.sizeBytes }
                self.finishScan(cancelled: false)
            }
        }
    }

    // MARK: - 보안 스코프 유지

    /// 현재 결과가 가리키는 폴더의 보안 스코프 접근을 유지(썸네일 로딩 위해).
    /// 다른 폴더로 바뀌면 이전 접근을 닫고 새 접근을 시작합니다.
    private var accessedFolderURL: URL? = nil

    private func beginFolderAccess(_ url: URL) {
        if accessedFolderURL == url { return }
        releaseFolderAccess()
        _ = url.startAccessingSecurityScopedResource()
        accessedFolderURL = url
    }

    private func releaseFolderAccess() {
        if let prev = accessedFolderURL {
            prev.stopAccessingSecurityScopedResource()
            accessedFolderURL = nil
        }
    }

    func cancelScan() {
        collectTask?.cancel()   // ✅ detached 수집 작업을 직접 취소(부모만 취소하면 전파 안 됨)
        scanTask?.cancel()
    }

    private func finishScan(cancelled: Bool) {
        isScanning = false
        phase = .done
        progress = 1.0
        if cancelled {
            lastScanDate = nil
            statusMessage = "photos.status.cancelled".localized
        } else {
            lastScanDate = Date()
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

            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            // ✅ 픽셀 크기 산출(파일별 디코딩)은 스캔에서 제거 — 썸네일 로드 시에만 필요
            let screenshot = screenshotPaths.contains(url.path) || matchesScreenshotName(url)

            result.append(PhotoItem(
                url: url,
                sizeBytes: size,
                modificationDate: values.contentModificationDate,
                pixelWidth: 0,
                pixelHeight: 0,
                isScreenshot: screenshot
            ))
        }

        return result
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
    nonisolated private static func matchesScreenshotName(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "png" else { return false }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return ["screenshot", "screen shot", "스크린샷"].contains { name.hasPrefix($0) || name.contains($0) }
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
