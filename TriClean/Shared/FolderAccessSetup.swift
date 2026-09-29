//
//  FolderAccessSetup.swift
//  TriClean
//
//  폴더 접근 권한을 한곳에서 받는다.
//
//  샌드박스 앱은 사용자가 NSOpenPanel로 고른 폴더에만 접근할 수 있다. 기존에는 화면마다
//  폴더를 따로 골라야 해서(Applications는 앱 삭제·저장 공간에서 두 번) 신규 사용자가
//  최대 7~8번 권한을 요청받았다. 여기서는 홈·응용 프로그램·라이브러리 세 폴더를 한 번씩
//  받아, 같은 폴더를 쓰는 모든 화면의 북마크 키에 함께 저장한다.
//
//  ⚠️ 폴더 여러 개를 한 번의 패널로 받을 수는 없다(샌드박스 제약). "한 번에"는
//     온보딩·설정의 한 화면에서 차례로 고르게 하는 방식이다.
//

import SwiftUI
import AppKit

@MainActor
enum FolderAccessSetup {

    enum Item: CaseIterable, Identifiable {
        case home, applications, library

        var id: Self { self }

        var icon: String {
            switch self {
            case .home: return "house"
            case .applications: return "square.grid.2x2"
            case .library: return "books.vertical"
            }
        }

        var titleKey: String {
            switch self {
            case .home: return "access.home.title"
            case .applications: return "access.apps.title"
            case .library: return "access.library.title"
            }
        }

        var descKey: String {
            switch self {
            case .home: return "access.home.desc"
            case .applications: return "access.apps.desc"
            case .library: return "access.library.desc"
            }
        }

        /// 이 항목의 권한 여부를 판단하는 대표 키
        fileprivate var primaryKey: TriCleanBookmarkKey {
            switch self {
            case .home: return .storageHomeFolder
            case .applications: return .appsApplicationsFolder
            case .library: return .appsUserLibraryFolder
            }
        }
    }

    enum Outcome {
        case granted
        case cancelled
        /// 다른 폴더를 골랐다(홈·라이브러리는 정확한 폴더여야 기능이 동작한다).
        case wrongFolder
        case saveFailed
    }

    private static let bookmarks = SecurityScopedBookmarkStore.shared

    /// 실제 홈 폴더. 샌드박스에서 `homeDirectoryForCurrentUser`는 컨테이너를 가리킨다.
    static var userHomeURL: URL {
        JunkScannerViewModel.userLibraryURL.deletingLastPathComponent()
    }

    static func isGranted(_ item: Item) -> Bool {
        guard let url = bookmarks.resolveURL(for: item.primaryKey),
              let token = SecurityScopedAccessToken(url: url) else { return false }
        defer { token.stop() }

        switch item {
        case .home:
            return DeletionSafety.isSameItem(url, userHomeURL)
        case .applications:
            return true
        case .library:
            return DeletionSafety.isSameItem(url, JunkScannerViewModel.userLibraryURL)
        }
    }

    /// 패널을 띄워 폴더를 받고, 그 폴더를 쓰는 모든 기능의 북마크에 저장한다.
    static func request(_ item: Item) -> Outcome {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "access.panel.prompt".localized

        switch item {
        case .home:
            panel.title = "storage.scope.select_home_title".localized
            panel.message = "access.home.desc".localized
            panel.directoryURL = userHomeURL
        case .applications:
            panel.title = "apps.scope.apps_folder".localized
            panel.message = "access.apps.desc".localized
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .library:
            panel.title = "apps.scope.library_folder".localized
            panel.message = "access.library.desc".localized
            panel.directoryURL = JunkScannerViewModel.userLibraryURL
        }

        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }

        switch item {
        case .home:
            guard DeletionSafety.isSameItem(url, userHomeURL) else { return .wrongFolder }
            guard bookmarks.trySave(url: url, for: .storageHomeFolder) else { return .saveFailed }
            // 스캔 폴더는 사용자가 이미 골라둔 값이 있으면 덮어쓰지 않는다.
            fillIfEmpty(.duplicateScanFolder, with: url)
            fillIfEmpty(.largeFilesScanFolder, with: url)
            if bookmarks.resolveURL(for: .photoScanFolder) == nil {
                // 홈 폴더 권한 안에서 하위 폴더 북마크를 만든다. 실패하면 홈 폴더로 대신한다.
                let pictures = url.appendingPathComponent("Pictures", isDirectory: true)
                let token = SecurityScopedAccessToken(url: url)
                defer { token?.stop() }
                if !(FileManager.default.fileExists(atPath: pictures.path)
                     && bookmarks.trySave(url: pictures, for: .photoScanFolder)) {
                    bookmarks.trySave(url: url, for: .photoScanFolder)
                }
            }

        case .applications:
            guard bookmarks.trySave(url: url, for: .appsApplicationsFolder) else { return .saveFailed }
            if bookmarks.resolveURLs(for: .storageApplicationsFolders).isEmpty {
                bookmarks.trySaveMany(urls: [url], for: .storageApplicationsFolders)
            }

        case .library:
            guard DeletionSafety.isSameItem(url, JunkScannerViewModel.userLibraryURL) else { return .wrongFolder }
            guard bookmarks.trySave(url: url, for: .appsUserLibraryFolder) else { return .saveFailed }
            bookmarks.trySave(url: url, for: .junkLibraryFolder)
        }

        return .granted
    }

    private static func fillIfEmpty(_ key: TriCleanBookmarkKey, with url: URL) {
        guard bookmarks.resolveURL(for: key) == nil else { return }
        bookmarks.trySave(url: url, for: key)
    }
}

// MARK: - UI

/// 온보딩과 설정에서 함께 쓰는 권한 설정 목록.
struct FolderAccessSetupView: View {
    @EnvironmentObject private var junkViewModel: JunkScannerViewModel
    @EnvironmentObject private var duplicateViewModel: DuplicateScannerViewModel
    @EnvironmentObject private var appsViewModel: AppsViewModel
    @EnvironmentObject private var photoViewModel: PhotoScannerViewModel
    @EnvironmentObject private var largeFilesViewModel: LargeFilesViewModel

    @State private var granted: Set<FolderAccessSetup.Item> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(FolderAccessSetup.Item.allCases) { item in
                row(item)
            }
            if let errorMessage {
                Text(errorMessage)
                    .appFont(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refresh)
    }

    private func row(_ item: FolderAccessSetup.Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .appIconFont(18, weight: .semibold)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.titleKey.localized)
                    .appFont(.body, weight: .semibold)
                Text(item.descKey.localized)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if granted.contains(item) {
                Label("access.granted".localized, systemImage: "checkmark.circle.fill")
                    .appFont(.caption, weight: .semibold)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("access.grant".localized) { request(item) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func refresh() {
        granted = Set(FolderAccessSetup.Item.allCases.filter(FolderAccessSetup.isGranted))
    }

    private func request(_ item: FolderAccessSetup.Item) {
        switch FolderAccessSetup.request(item) {
        case .granted:
            errorMessage = nil
            reloadViewModels()
        case .cancelled:
            break
        case .wrongFolder:
            errorMessage = (item == .home ? "access.error.home" : "access.error.library").localized
        case .saveFailed:
            errorMessage = "access.error.save".localized
        }
        refresh()
    }

    /// 앱 수준 ViewModel은 실행 시 한 번만 북마크를 읽으므로, 새로 받은 권한을 반영시킨다.
    private func reloadViewModels() {
        junkViewModel.reloadSharedFolderAccess()
        duplicateViewModel.reloadSharedFolderAccess()
        appsViewModel.reloadSharedFolderAccess()
        photoViewModel.reloadSharedFolderAccess()
        largeFilesViewModel.reloadSharedFolderAccess()
    }
}
