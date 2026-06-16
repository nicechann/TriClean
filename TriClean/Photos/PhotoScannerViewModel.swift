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
import ImageIO
import UniformTypeIdentifiers

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
        phase = .collecting
        statusMessage = "photos.status.collecting".localized

        let root = folderURL.standardizedFileURL

        scanTask = Task {
            let started = root.startAccessingSecurityScopedResource()
            defer { if started { root.stopAccessingSecurityScopedResource() } }

            let collected = await Task.detached(priority: .utility) {
                Self.collectImages(in: root)
            }.value

            guard !Task.isCancelled else {
                finishScan()
                return
            }

            // 큰 파일(용량 우선)이 먼저 보이도록 정렬
            self.items = collected.sorted { $0.sizeBytes > $1.sizeBytes }
            finishScan()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func finishScan() {
        isScanning = false
        phase = .done
        progress = 1.0
        lastScanDate = Date()
        statusMessage = items.isEmpty
            ? "photos.status.empty".localized
            : "photos.status.found".localized(with: items.count)
    }

    // MARK: - 이미지 수집 (백그라운드)

    nonisolated private static func collectImages(in root: URL) -> [PhotoItem] {
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
            let (w, h) = imagePixelSize(url: url)

            result.append(PhotoItem(
                url: url,
                sizeBytes: size,
                modificationDate: values.contentModificationDate,
                pixelWidth: w,
                pixelHeight: h
            ))
        }

        return result
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

    /// 전체 디코딩 없이 헤더 속성만 읽어 픽셀 크기를 구합니다.
    nonisolated private static func imagePixelSize(url: URL) -> (Int, Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        let width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return (width, height)
    }
}
