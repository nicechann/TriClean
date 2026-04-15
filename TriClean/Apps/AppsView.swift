//
//  AppsView.swift
//  TriClean
//
//  Created by changyu Kang on 08/12/2025.
//

import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import CoreServices

// MARK: - AppsView 전용 Security-Scoped Bookmark 유틸

private enum AppsBookmarkKey: String {
    case applicationsFolder = "TriClean.Apps.Bookmark.ApplicationsFolder"
    case userLibraryFolder  = "TriClean.Apps.Bookmark.UserLibraryFolder"
    case manualAppBundle    = "TriClean.Apps.Bookmark.ManualAppBundle"
}

private enum AppsSecurityScopedBookmarks {
    static func save(url: URL, key: AppsBookmarkKey) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: key.rawValue)
    }

    static func load(key: AppsBookmarkKey) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale { try? save(url: url, key: key) }
            return url
        } catch {
            return nil
        }
    }

    static func clear(key: AppsBookmarkKey) {
        UserDefaults.standard.removeObject(forKey: key.rawValue)
    }
}

private final class AppsScopedAccessToken: @unchecked Sendable {
    private let url: URL
    private let started: Bool

    private let lock = NSLock()
    private var didStop = false

    init?(url: URL) {
        self.url = url
        self.started = url.startAccessingSecurityScopedResource()
        if !started { return nil }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard started, !didStop else { return }
        didStop = true
        url.stopAccessingSecurityScopedResource()
    }

    deinit { stop() }
}

// MARK: - Models

enum AppsListFilter: String, CaseIterable, Identifiable {
    case all
    case removable
    case appStore
    case protectedApps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "apps.filter.all".localized
        case .removable: return "apps.filter.removable".localized
        case .appStore: return "apps.filter.appstore".localized
        case .protectedApps: return "apps.filter.protected".localized
        }
    }
}

struct AppsInstalledApp: Identifiable, Hashable, Sendable {
    let name: String
    let bundleID: String?
    let url: URL
    let canUninstall: Bool
    let isSystemApp: Bool
    let isAppStoreApp: Bool
    let modifiedDate: Date?

    // 미리 계산된 문자열 저장
    let id: String
    let location: String

    var typeDescription: String {
        if isSystemApp { return "apps.type.system".localized }
        if isAppStoreApp { return "apps.type.appstore".localized }
        return canUninstall ? "apps.type.user".localized : "apps.type.protected".localized
    }

    var modifiedDateText: String {
        guard let modifiedDate else { return "-" }
        return modifiedDate.formatted(date: .abbreviated, time: .omitted)
    }

    nonisolated init(name: String, bundleID: String?, url: URL, canUninstall: Bool, isSystemApp: Bool, isAppStoreApp: Bool, modifiedDate: Date?) {
        self.name = name
        self.bundleID = bundleID
        self.url = url
        self.canUninstall = canUninstall
        self.isSystemApp = isSystemApp
        self.isAppStoreApp = isAppStoreApp
        self.modifiedDate = modifiedDate
        self.id = url.path(percentEncoded: false)
        self.location = url.deletingLastPathComponent().path(percentEncoded: false)
    }
}

struct AppsRelatedItem: Identifiable, Hashable, Sendable {
    let url: URL
    var selected: Bool
    let isDirectory: Bool
    let sizeBytes: Int64

    let id: String
    let path: String
    let name: String

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    nonisolated init(url: URL, selected: Bool, isDirectory: Bool, sizeBytes: Int64 = 0) {
        self.url = url
        self.selected = selected
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes

        let rawPath = url.path(percentEncoded: false)
        self.id = rawPath
        self.path = rawPath
        self.name = url.lastPathComponent
    }

    static func == (lhs: AppsRelatedItem, rhs: AppsRelatedItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct AppsSelectedAppInfo: Sendable {
    let name: String
    let bundleID: String?
    let appPath: String
    let modifiedDate: Date?
}

enum AppsActiveAlert: Identifiable {
    case uninstallApps
    case uninstallPartialFail(successCount: Int, failedCount: Int)
    case removeRelatedFiles
    case resetPermissions

    var id: String {
        switch self {
        case .uninstallApps: return "uninstallApps"
        case .uninstallPartialFail: return "uninstallPartialFail"
        case .removeRelatedFiles: return "removeRelatedFiles"
        case .resetPermissions: return "resetPermissions"
        }
    }
}

// MARK: - ViewModel

@MainActor
final class AppsViewModel: ObservableObject {

    // 사용자 선택 범위
    @Published private(set) var applicationsFolderURL: URL?
    @Published private(set) var userLibraryFolderURL: URL?
    @Published private(set) var manualAppBundleURL: URL?

    // 목록/선택
    @Published var installedApps: [AppsInstalledApp] = []
    @Published var selectedInstalledAppIDs: Set<String> = []
    @Published var searchText: String = ""
    @Published var listFilter: AppsListFilter = .all

    // 상세/관련 파일
    @Published var selectedApp: AppsSelectedAppInfo?
    @Published var relatedItems: [AppsRelatedItem] = []

    // 상태
    @Published var isLoadingInstalledApps: Bool = false
    @Published var isScanning: Bool = false
    @Published var isRemoving: Bool = false
    @Published var lastStatusMessage: String?
    @Published var lastStatusIsError: Bool = false

    private var lastFailedApps: [AppsInstalledApp] = []

    init() {
        applicationsFolderURL = AppsSecurityScopedBookmarks.load(key: .applicationsFolder)
        userLibraryFolderURL  = AppsSecurityScopedBookmarks.load(key: .userLibraryFolder)
        manualAppBundleURL    = AppsSecurityScopedBookmarks.load(key: .manualAppBundle)
    }

    // MARK: - Derived

    var filteredInstalledApps: [AppsInstalledApp] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = installedApps.filter { app in
            guard !q.isEmpty else { return true }
            let lower = q.lowercased()
            return app.name.lowercased().contains(lower)
            || (app.bundleID?.lowercased().contains(lower) ?? false)
            || app.id.lowercased().contains(lower)
        }

        return searched.filter { app in
            switch listFilter {
            case .all:
                return true
            case .removable:
                return app.canUninstall
            case .appStore:
                return app.isAppStoreApp
            case .protectedApps:
                return !app.canUninstall
            }
        }
    }

    var selectedInstalledApps: [AppsInstalledApp] {
        installedApps.filter { selectedInstalledAppIDs.contains($0.id) }
    }

    var deletableSelectedApps: [AppsInstalledApp] {
        selectedInstalledApps.filter { $0.canUninstall }
    }

    var totalAppsCount: Int { installedApps.count }
    var removableAppsCount: Int { installedApps.filter(\.canUninstall).count }
    var appStoreAppsCount: Int { installedApps.filter(\.isAppStoreApp).count }
    var protectedAppsCount: Int { installedApps.filter { !$0.canUninstall && !$0.isAppStoreApp }.count }
    var selectedAppsCount: Int { selectedInstalledApps.count }
    var selectedRemovableCount: Int { deletableSelectedApps.count }

    var selectedRelatedItems: [AppsRelatedItem] {
        relatedItems.filter(\.selected)
    }

    var selectedRelatedCount: Int { selectedRelatedItems.count }

    var selectedRelatedBytes: Int64 {
        selectedRelatedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var totalRelatedBytes: Int64 {
        relatedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedRelatedSizeText: String {
        ByteCountFormatter.string(fromByteCount: selectedRelatedBytes, countStyle: .file)
    }

    var totalRelatedSizeText: String {
        ByteCountFormatter.string(fromByteCount: totalRelatedBytes, countStyle: .file)
    }

    var uninstallButtonHelpText: String {
        if isRemoving { return "apps.help.removing".localized }

        let selected = selectedInstalledApps.count
        let deletable = deletableSelectedApps.count

        if selected == 0 { return "apps.help.select_first".localized }
        if deletable == 0 { return "apps.help.all_protected".localized }
        if deletable < selected { return "apps.help.partial_protected".localized }
        return "apps.help.move_trash".localized
    }

    var selectionSummaryText: String {
        if selectedAppsCount == 0 {
            return "apps.selection.none".localized(with: filteredInstalledApps.count)
        }
        return "apps.selection.summary".localized(with: selectedAppsCount, selectedRemovableCount)
    }

    // MARK: - User Choice: Scope selection

    func selectApplicationsFolder() {
        let panel = NSOpenPanel()
        panel.title = "apps.scope.apps_folder".localized
        panel.message = "apps.scope.apps_msg".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try AppsSecurityScopedBookmarks.save(url: url, key: .applicationsFolder)
                applicationsFolderURL = url
                lastStatusIsError = false
                lastStatusMessage = "apps.status.folder_selected".localized(with: url.path)
                loadInstalledApps()
            } catch {
                lastStatusIsError = true
                lastStatusMessage = "apps.status.bookmark_fail".localized(with: error.localizedDescription)
            }
        }
    }

    func selectUserLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "apps.scope.library_folder".localized
        panel.message = "apps.scope.library_msg".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try AppsSecurityScopedBookmarks.save(url: url, key: .userLibraryFolder)
                userLibraryFolderURL = url
                lastStatusIsError = false
                lastStatusMessage = "apps.status.library_selected".localized(with: url.path)
            } catch {
                lastStatusIsError = true
                lastStatusMessage = "apps.status.bookmark_fail".localized(with: error.localizedDescription)
            }
        }
    }

    func resetPermissions() {
        AppsSecurityScopedBookmarks.clear(key: .applicationsFolder)
        AppsSecurityScopedBookmarks.clear(key: .userLibraryFolder)
        AppsSecurityScopedBookmarks.clear(key: .manualAppBundle)

        applicationsFolderURL = nil
        userLibraryFolderURL = nil
        manualAppBundleURL = nil

        installedApps = []
        selectedInstalledAppIDs = []
        selectedApp = nil
        relatedItems = []
        listFilter = .all

        lastStatusIsError = false
        lastStatusMessage = "apps.status.reset_success".localized
    }

    // MARK: - Manual app selection (.app)

    func selectAppBundleManually() {
        let panel = NSOpenPanel()
        panel.title = "apps.manual.title".localized
        panel.message = "apps.manual.msg".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try AppsSecurityScopedBookmarks.save(url: url, key: .manualAppBundle)
                manualAppBundleURL = url
                handleManuallySelectedApp(at: url)
            } catch {
                lastStatusIsError = true
                lastStatusMessage = "apps.status.app_bookmark_fail".localized(with: error.localizedDescription)
            }
        }
    }

    private func handleManuallySelectedApp(at appURL: URL) {
        guard let token = AppsScopedAccessToken(url: appURL) else {
            lastStatusIsError = true
            lastStatusMessage = "apps.status.no_permission".localized
            return
        }
        defer { token.stop() }

        let std = appURL.standardizedFileURL
        guard std.pathExtension.lowercased() == "app" else {
            lastStatusIsError = true
            lastStatusMessage = "apps.status.not_app_bundle".localized
            return
        }

        if let existing = installedApps.first(where: { $0.url.standardizedFileURL == std }) {
            selectedInstalledAppIDs = [existing.id]
            analyzeInstalledApp(app: existing)
            lastStatusIsError = false
            lastStatusMessage = "apps.status.app_selected".localized(with: existing.name)
            return
        }

        guard let new = buildInstalledAppOnMain(from: std) else {
            lastStatusIsError = true
            lastStatusMessage = "apps.status.read_fail".localized
            return
        }

        installedApps.append(new)
        installedApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        selectedInstalledAppIDs = [new.id]
        analyzeInstalledApp(app: new)
        lastStatusIsError = false
        lastStatusMessage = "apps.status.app_added".localized(with: new.name)
    }

    private func buildInstalledAppOnMain(from url: URL) -> AppsInstalledApp? {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier
        let modifiedDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        return Self.makeAppModel(url: url, name: name, bundleID: bundleID, modifiedDate: modifiedDate)
    }

    // MARK: - Load Installed Apps

    func loadInstalledApps() {
        guard let root = applicationsFolderURL?.standardizedFileURL else {
            lastStatusIsError = true
            lastStatusMessage = "apps.status.folder_needed".localized
            return
        }
        guard let token = AppsScopedAccessToken(url: root) else {
            lastStatusIsError = true
            lastStatusMessage = "apps.status.scoped_error".localized
            return
        }

        let rootStd = root.standardizedFileURL

        isLoadingInstalledApps = true
        lastStatusIsError = false
        lastStatusMessage = "apps.list.loading".localized

        Task {
            defer { token.stop() }

            let scanned = await Task.detached(priority: .userInitiated) {
                AppsViewModel.scanApps(in: rootStd, maxDepth: 2)
            }.value

            let sorted = scanned.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            guard self.applicationsFolderURL?.standardizedFileURL == rootStd else {
                self.isLoadingInstalledApps = false
                return
            }

            self.installedApps = sorted
            self.selectedInstalledAppIDs.removeAll()
            self.selectedApp = nil
            self.relatedItems = []

            self.isLoadingInstalledApps = false
            self.lastStatusIsError = false
            self.lastStatusMessage = "apps.status.loaded_count".localized(with: sorted.count)
        }
    }

    nonisolated private static func scanApps(in dir: URL, maxDepth: Int = 2) -> [AppsInstalledApp] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var apps: [AppsInstalledApp] = []

        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            if url.pathExtension.lowercased() == "app" {
                if let app = buildInstalledAppWithoutBundle(from: url) {
                    apps.append(app)
                }
                enumerator.skipDescendants()
            }
        }

        return apps
    }

    nonisolated private static func buildInstalledAppWithoutBundle(from url: URL) -> AppsInstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        var name: String?
        var bundleID: String?

        if FileManager.default.fileExists(atPath: plistURL.path),
           let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            name = plist["CFBundleName"] as? String
            bundleID = plist["CFBundleIdentifier"] as? String
        }

        let modifiedDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let finalName = name ?? url.deletingPathExtension().lastPathComponent
        return makeAppModel(url: url, name: finalName, bundleID: bundleID, modifiedDate: modifiedDate)
    }

    nonisolated private static func makeAppModel(url: URL, name: String, bundleID: String?, modifiedDate: Date?) -> AppsInstalledApp {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        let canDelete = fm.isDeletableFile(atPath: url.path) && fm.isWritableFile(atPath: parent.path)

        let isSystemPath = url.path.hasPrefix("/System/Applications")
        let isApple = bundleID?.hasPrefix("com.apple.") ?? false
        let isSystemApp = isSystemPath || (isApple && !canDelete)
        let isAppStoreApp = fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        let canUninstall = canDelete && !isSystemApp && !isAppStoreApp

        return AppsInstalledApp(
            name: name,
            bundleID: bundleID,
            url: url,
            canUninstall: canUninstall,
            isSystemApp: isSystemApp,
            isAppStoreApp: isAppStoreApp,
            modifiedDate: modifiedDate
        )
    }

    // MARK: - Details Scan

    func analyzeInstalledApp(app: AppsInstalledApp) {
        analyzeInstalledApp(url: app.url, modifiedDate: app.modifiedDate)
    }

    private func analyzeInstalledApp(url appURL: URL, modifiedDate: Date? = nil) {
        let bundle = Bundle(url: appURL)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier

        selectedApp = AppsSelectedAppInfo(name: name, bundleID: bundleID, appPath: appURL.path, modifiedDate: modifiedDate)
        relatedItems = []

        guard userLibraryFolderURL != nil else {
            lastStatusIsError = false
            lastStatusMessage = "apps.status.library_guide".localized
            return
        }

        scanRelatedFiles(for: name, bundleID: bundleID)
    }

    private func scanRelatedFiles(for appName: String, bundleID: String?) {
        guard let library = userLibraryFolderURL?.standardizedFileURL else {
            lastStatusIsError = true
            lastStatusMessage = "apps.status.library_needed".localized
            return
        }
        guard let token = AppsScopedAccessToken(url: library) else {
            lastStatusIsError = true
            lastStatusMessage = "apps.status.library_scoped_error".localized
            return
        }

        let libraryStd = library.standardizedFileURL

        isScanning = true
        lastStatusIsError = false
        lastStatusMessage = "apps.status.scanning".localized

        Task {
            defer { token.stop() }

            let found = await Task.detached(priority: .userInitiated) {
                AppsViewModel.findRelatedItems(in: libraryStd, appName: appName, bundleID: bundleID)
            }.value

            guard self.userLibraryFolderURL?.standardizedFileURL == libraryStd else {
                self.isScanning = false
                return
            }

            self.relatedItems = found
            self.isScanning = false

            self.lastStatusMessage = found.isEmpty
                ? "apps.status.scan_empty".localized
                : "apps.status.scan_found".localized(with: found.count)
        }
    }

    nonisolated private static func findRelatedItems(in libraryRoot: URL, appName: String, bundleID: String?) -> [AppsRelatedItem] {
        var dict: [String: AppsRelatedItem] = [:]
        let fm = FileManager.default

        func upsert(_ item: AppsRelatedItem) {
            dict[item.id] = item
        }

        if let bundleID, !bundleID.isEmpty {
            for item in runSpotlightQuery(in: libraryRoot, bundleID: bundleID) {
                upsert(item)
            }

            let strictPaths: [(sub: String, suffix: String?)] = [
                ("Preferences", ".plist"),
                ("Containers", nil),
                ("Group Containers", nil),
                ("Caches", nil),
                ("Saved Application State", ".savedState"),
                ("WebKit", nil),
                ("HTTPStorages", nil)
            ]

            for (sub, suffix) in strictPaths {
                let dir = libraryRoot.appendingPathComponent(sub)
                var targetName = bundleID
                if let s = suffix { targetName += s }
                let targetURL = dir.appendingPathComponent(targetName)

                if fm.fileExists(atPath: targetURL.path) {
                    let isDir = (try? targetURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let sizeBytes = fileSize(at: targetURL)
                    upsert(AppsRelatedItem(url: targetURL, selected: true, isDirectory: isDir, sizeBytes: sizeBytes))
                }
            }
        }

        if !appName.isEmpty {
            let namePaths = ["Application Support", "Caches"]
            for sub in namePaths {
                let dir = libraryRoot.appendingPathComponent(sub)
                let targetURL = dir.appendingPathComponent(appName)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue {
                    let sizeBytes = fileSize(at: targetURL)
                    upsert(AppsRelatedItem(url: targetURL, selected: true, isDirectory: true, sizeBytes: sizeBytes))
                }
            }
        }

        return Array(dict.values).sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    nonisolated private static func runSpotlightQuery(in searchScope: URL, bundleID: String) -> [AppsRelatedItem] {
        let escaped = bundleID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let queryString = "kMDItemCFBundleIdentifier == \"\(escaped)\""

        guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, nil, nil) else {
            return []
        }

        MDQuerySetSearchScope(query, [searchScope.path] as CFArray, 0)

        let ok = MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
        guard ok else { return [] }

        let count = Int(MDQueryGetResultCount(query))
        guard count > 0 else { return [] }

        var found: [AppsRelatedItem] = []
        found.reserveCapacity(min(count, 512))

        for i in 0..<count {
            guard let rawPtr = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(rawPtr).takeUnretainedValue()

            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String, !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.path.hasPrefix(searchScope.path) else { continue }

            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let sizeBytes = fileSize(at: url)
            found.append(AppsRelatedItem(url: url, selected: true, isDirectory: isDir, sizeBytes: sizeBytes))
        }

        return found
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]

        if let values = try? url.resourceValues(forKeys: keys) {
            if values.isDirectory == true {
                return directorySize(at: url)
            }
            if let total = values.totalFileAllocatedSize { return Int64(total) }
            if let allocated = values.fileAllocatedSize { return Int64(allocated) }
            if let fileSize = values.fileSize { return Int64(fileSize) }
        }
        return 0
    }

    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]) {
                if values.isDirectory == true { continue }
                if let allocated = values.totalFileAllocatedSize {
                    total += Int64(allocated)
                } else if let fileAllocated = values.fileAllocatedSize {
                    total += Int64(fileAllocated)
                } else if let fileSize = values.fileSize {
                    total += Int64(fileSize)
                }
            }
        }
        return total
    }

    // MARK: - Selection helpers

    func selectVisibleRemovableApps() {
        let visibleIDs = filteredInstalledApps.filter(\.canUninstall).map(\.id)
        selectedInstalledAppIDs.formUnion(visibleIDs)
    }

    func clearSelectedApps() {
        selectedInstalledAppIDs.removeAll()
    }

    // MARK: - Uninstall

    func revealInFinder(app: AppsInstalledApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    func revealFailedApps() {
        guard !lastFailedApps.isEmpty else { return }
        let urls = lastFailedApps.map { $0.url }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func uninstallSelectedInstalledApps(completion: @escaping (AppsActiveAlert?) -> Void) {
        let targets = deletableSelectedApps
        guard !targets.isEmpty else {
            lastStatusIsError = true
            lastStatusMessage = "apps.status.nothing_to_trash".localized
            return
        }

        isRemoving = true
        lastStatusMessage = nil
        lastStatusIsError = false

        var scopeTokens: [AppsScopedAccessToken] = []
        if let url = applicationsFolderURL, let t = AppsScopedAccessToken(url: url) { scopeTokens.append(t) }
        if let url = manualAppBundleURL, let t = AppsScopedAccessToken(url: url) { scopeTokens.append(t) }

        Task {
            defer { scopeTokens.forEach { $0.stop() } }

            let (succeeded, failed) = await Task.detached(priority: .userInitiated) {
                await AppsViewModel.performUninstall(targets: targets)
            }.value

            self.isRemoving = false
            self.lastFailedApps = failed

            let successIDs = Set(succeeded.map(\.id))
            if !successIDs.isEmpty {
                self.installedApps.removeAll { successIDs.contains($0.id) }
                self.selectedInstalledAppIDs.subtract(successIDs)

                if let selected = self.selectedApp, successIDs.contains(selected.appPath) {
                    self.selectedApp = nil
                    self.relatedItems = []
                }
            }

            if succeeded.isEmpty && !failed.isEmpty {
                self.lastStatusIsError = true
                self.lastStatusMessage = "apps.status.uninstall_all_fail".localized
                completion(.uninstallPartialFail(successCount: 0, failedCount: failed.count))
            } else if !succeeded.isEmpty && failed.isEmpty {
                self.lastStatusIsError = false
                self.lastStatusMessage = "apps.status.uninstall_success".localized(with: succeeded.count)
                completion(nil)
            } else if !succeeded.isEmpty && !failed.isEmpty {
                self.lastStatusIsError = true
                self.lastStatusMessage = "apps.status.uninstall_partial_fail".localized(with: succeeded.count, failed.count)
                completion(.uninstallPartialFail(successCount: succeeded.count, failedCount: failed.count))
            } else {
                completion(nil)
            }
        }
    }

    nonisolated private static func performUninstall(
        targets: [AppsInstalledApp]
    ) async -> ([AppsInstalledApp], [AppsInstalledApp]) {
        let fm = FileManager.default
        var succeeded: [AppsInstalledApp] = []
        var failed: [AppsInstalledApp] = []

        for app in targets {
            do {
                try fm.trashItem(at: app.url, resultingItemURL: nil)
                succeeded.append(app)
            } catch {
                let ok = await moveItemToTrashUsingWorkspace(url: app.url)
                if ok { succeeded.append(app) }
                else { failed.append(app) }
            }
        }

        return (succeeded, failed)
    }

    nonisolated private static func moveItemToTrashUsingWorkspace(url: URL) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                NSWorkspace.shared.recycle([url]) { _, error in
                    if let error = error {
                        print("NSWorkspace 삭제 실패: \(error)")
                        continuation.resume(returning: false)
                    } else {
                        continuation.resume(returning: true)
                    }
                }
            }
        }
    }

    func removeSelectedRelatedItems() {
        let targets = relatedItems.filter { $0.selected }
        guard !targets.isEmpty else { return }

        isRemoving = true
        lastStatusMessage = nil

        var scopeTokens: [AppsScopedAccessToken] = []
        if let root = userLibraryFolderURL, let t = AppsScopedAccessToken(url: root) { scopeTokens.append(t) }

        Task {
            defer { scopeTokens.forEach { $0.stop() } }

            let (succeeded, failed) = await Task.detached(priority: .userInitiated) {
                await AppsViewModel.performRelatedRemoval(targets: targets)
            }.value

            self.isRemoving = false

            let successIDs = Set(succeeded.map(\.id))
            if !successIDs.isEmpty {
                self.relatedItems.removeAll { successIDs.contains($0.id) }
            }

            if !failed.isEmpty {
                self.lastStatusIsError = true
                self.lastStatusMessage = "apps.status.related_partial_fail".localized(with: succeeded.count, failed.count)
            } else if !succeeded.isEmpty {
                self.lastStatusIsError = false
                self.lastStatusMessage = "apps.status.related_success".localized(with: succeeded.count)
            } else {
                self.lastStatusIsError = true
                self.lastStatusMessage = "apps.status.related_none".localized
            }
        }
    }

    nonisolated private static func performRelatedRemoval(
        targets: [AppsRelatedItem]
    ) async -> ([AppsRelatedItem], [AppsRelatedItem]) {
        let fm = FileManager.default
        var succeeded: [AppsRelatedItem] = []
        var failed: [AppsRelatedItem] = []

        for item in targets {
            do {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
                succeeded.append(item)
            } catch {
                let ok = await moveItemToTrashUsingWorkspace(url: item.url)
                if ok { succeeded.append(item) }
                else { failed.append(item) }
            }
        }

        return (succeeded, failed)
    }

    func failedAppNamesForAlert(maxCount: Int = 6) -> String {
        let names = lastFailedApps.map(\.name).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !names.isEmpty else { return "" }

        if names.count <= maxCount {
            return names.joined(separator: ", ")
        }

        let head = names.prefix(maxCount).joined(separator: ", ")
        return "\(head) 외 \(names.count - maxCount)개"
    }
}

// MARK: - View

struct AppsView: View {
    @StateObject private var viewModel = AppsViewModel()
    @State private var activeAlert: AppsActiveAlert?
    @State private var hoveredAppID: String? = nil
    @State private var showCompactDetailsSheet = false

    private let inspectorBreakpoint: CGFloat = 1400
    private let inspectorMinWidth: CGFloat = 340
    private let inspectorMaxWidth: CGFloat = 420

    var body: some View {
        GeometryReader { proxy in
            let useInspector = proxy.size.width >= inspectorBreakpoint

            Group {
                if useInspector {
                    regularLayout(size: proxy.size)
                } else {
                    compactLayout(size: proxy.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding()
        .alert(item: $activeAlert) { makeAlert($0) }
        .sheet(isPresented: $showCompactDetailsSheet) {
            compactDetailsSheet
        }
    }

    private func regularLayout(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            topSections(compact: false)

            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    appsTableSection(compact: false, useInspector: true)

                    if let status = viewModel.lastStatusMessage {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(viewModel.lastStatusIsError ? .red : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                inspectorPanel
                    .frame(minWidth: inspectorMinWidth,
                           idealWidth: min(max(size.width * 0.30, inspectorMinWidth), inspectorMaxWidth),
                           maxWidth: inspectorMaxWidth,
                           maxHeight: .infinity,
                           alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func compactLayout(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            topSections(compact: true)
            appsTableSection(compact: true, useInspector: false)

            if let status = viewModel.lastStatusMessage {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(viewModel.lastStatusIsError ? .red : .secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func topSections(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            scopePermissionsCard
            headerSection(compact: compact)
            summaryCards(compact: compact)
            safetyNoticeCard
            filterAndActionBar(compact: compact)
        }
    }

    private var compactDetailsSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                relatedFilesSection
                Spacer(minLength: 0)
            }
            .padding()
            .frame(minWidth: 620, minHeight: 560)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) {
                        showCompactDetailsSheet = false
                    }
                }
            }
        }
    }

    private var scopePermissionsCard: some View {
        GroupBox {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: viewModel.applicationsFolderURL == nil ? "xmark.circle" : "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(viewModel.applicationsFolderURL == nil ? Color.secondary : Color.green)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("apps.list.title".localized)
                            .font(.subheadline).bold()
                        Text(viewModel.applicationsFolderURL?.path ?? "apps.scope.apps_folder".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button("apps.scope.apps_folder".localized) {
                        viewModel.selectApplicationsFolder()
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Image(systemName: viewModel.userLibraryFolderURL == nil ? "xmark.circle" : "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(viewModel.userLibraryFolderURL == nil ? Color.secondary : Color.green)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("apps.scope.library_analysis".localized)
                            .font(.subheadline).bold()
                        Text(viewModel.userLibraryFolderURL?.path ?? "apps.status.library_needed".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button("apps.scope.library_folder".localized) {
                        viewModel.selectUserLibraryFolder()
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        viewModel.loadInstalledApps()
                    } label: {
                        Label("common.scan".localized, systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.applicationsFolderURL == nil || viewModel.isLoadingInstalledApps || viewModel.isRemoving)

                    Spacer()

                    Button("apps.scope.reset".localized) {
                        activeAlert = .resetPermissions
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(4)
        }
        .layoutPriority(1)
    }

    private func headerSection(compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("apps.header.uninstall".localized)
                            .font(.title).bold()
                        Text("apps.header.desc".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Spacer()
                        Button("apps.btn.manual_select".localized) {
                            viewModel.selectAppBundleManually()
                        }
                    }
                }
            } else {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("apps.header.uninstall".localized)
                            .font(.title).bold()
                        Text("apps.header.desc".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("apps.btn.manual_select".localized) {
                        viewModel.selectAppBundleManually()
                    }
                }
            }
        }
    }

    private func summaryCards(compact: Bool) -> some View {
        Group {
            if compact {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    appsSummaryCard(titleKey: "apps.summary.total", value: "\(viewModel.totalAppsCount)", icon: "square.stack.3d.up")
                    appsSummaryCard(titleKey: "apps.summary.removable", value: "\(viewModel.removableAppsCount)", icon: "trash")
                    appsSummaryCard(titleKey: "apps.summary.appstore", value: "\(viewModel.appStoreAppsCount)", icon: "bag")
                    appsSummaryCard(titleKey: "apps.summary.selected", value: "\(viewModel.selectedAppsCount)", icon: "checkmark.circle")
                }
            } else {
                HStack(spacing: 10) {
                    appsSummaryCard(titleKey: "apps.summary.total", value: "\(viewModel.totalAppsCount)", icon: "square.stack.3d.up")
                    appsSummaryCard(titleKey: "apps.summary.removable", value: "\(viewModel.removableAppsCount)", icon: "trash")
                    appsSummaryCard(titleKey: "apps.summary.appstore", value: "\(viewModel.appStoreAppsCount)", icon: "bag")
                    appsSummaryCard(titleKey: "apps.summary.selected", value: "\(viewModel.selectedAppsCount)", icon: "checkmark.circle")
                }
            }
        }
    }

    private var safetyNoticeCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("apps.safety.title".localized, systemImage: "shield.checkered")
                    .font(.subheadline.bold())
                Text("apps.safety.desc".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func filterAndActionBar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if compact {
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        TextField("apps.search.placeholder".localized, text: $viewModel.searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(6)
                    .background(.quaternary)
                    .cornerRadius(8)

                    Picker("apps.filter.label".localized, selection: $viewModel.listFilter) {
                        ForEach(AppsListFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }

                HStack(spacing: 10) {
                    Button("apps.btn.select_visible".localized) {
                        viewModel.selectVisibleRemovableApps()
                    }
                    .disabled(viewModel.filteredInstalledApps.filter(\.canUninstall).isEmpty || viewModel.isRemoving)

                    Button("apps.btn.clear_selection".localized) {
                        viewModel.clearSelectedApps()
                    }
                    .disabled(viewModel.selectedAppsCount == 0 || viewModel.isRemoving)

                    Spacer()

                    Button("apps.btn.uninstall".localized) {
                        activeAlert = .uninstallApps
                    }
                    .frame(width: 120)
                    .disabled(viewModel.deletableSelectedApps.isEmpty || viewModel.isRemoving)
                    .help(viewModel.uninstallButtonHelpText)
                }
            } else {
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        TextField("apps.search.placeholder".localized, text: $viewModel.searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(6)
                    .background(.quaternary)
                    .cornerRadius(8)

                    Picker("apps.filter.label".localized, selection: $viewModel.listFilter) {
                        ForEach(AppsListFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 170)

                    Spacer()

                    Button("apps.btn.select_visible".localized) {
                        viewModel.selectVisibleRemovableApps()
                    }
                    .disabled(viewModel.filteredInstalledApps.filter(\.canUninstall).isEmpty || viewModel.isRemoving)

                    Button("apps.btn.clear_selection".localized) {
                        viewModel.clearSelectedApps()
                    }
                    .disabled(viewModel.selectedAppsCount == 0 || viewModel.isRemoving)

                    Button("apps.btn.uninstall".localized) {
                        activeAlert = .uninstallApps
                    }
                    .frame(width: 120)
                    .disabled(viewModel.deletableSelectedApps.isEmpty || viewModel.isRemoving)
                    .help(viewModel.uninstallButtonHelpText)
                }
            }

            Text(viewModel.selectionSummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func appsTableSection(compact: Bool, useInspector: Bool) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.isLoadingInstalledApps {
                    HStack { ProgressView(); Text("apps.list.loading".localized); Spacer() }
                } else if viewModel.applicationsFolderURL == nil {
                    Text("apps.list.guide_select".localized)
                        .foregroundStyle(.secondary)
                } else if viewModel.filteredInstalledApps.isEmpty {
                    Text("apps.list.empty".localized)
                        .foregroundStyle(.secondary)
                } else {
                    appsTable(compact: compact, useInspector: useInspector)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
        } label: {
            Text("apps.list.title".localized).font(.headline)
        }
    }

    private func appsTable(compact: Bool, useInspector: Bool) -> some View {
        Group {
            if compact {
                compactAppsTable(useInspector: useInspector)
            } else {
                regularAppsTable(useInspector: useInspector)
            }
        }
    }

    private func compactAppsTable(useInspector: Bool) -> some View {
        Table(viewModel.filteredInstalledApps) {
            TableColumn("") { app in
                rowBackground(appID: app.id) {
                    if app.canUninstall {
                        Toggle("", isOn: Binding(
                            get: { viewModel.selectedInstalledAppIDs.contains(app.id) },
                            set: { isOn in
                                if isOn { viewModel.selectedInstalledAppIDs.insert(app.id) }
                                else { viewModel.selectedInstalledAppIDs.remove(app.id) }
                            })
                        )
                        .labelsHidden()
                    } else {
                        Image(systemName: app.isSystemApp ? "lock.shield.fill" : "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(28)

            TableColumn("apps.table.app".localized) { app in
                rowBackground(appID: app.id) {
                    Text(app.name)
                }
            }

            TableColumn("apps.table.type".localized) { app in
                rowBackground(appID: app.id) {
                    Text(app.typeDescription).foregroundStyle(.secondary)
                }
            }
            .width(90)

            TableColumn("apps.table.modified".localized) { app in
                rowBackground(appID: app.id) {
                    Text(app.modifiedDateText).foregroundStyle(.secondary)
                }
            }
            .width(110)

            TableColumn("apps.table.operation".localized) { app in
                rowBackground(appID: app.id) {
                    HStack(spacing: 8) {
                        Button("apps.btn.details".localized) { openDetails(for: app, useInspector: useInspector) }
                        Button("common.finder_app".localized) { viewModel.revealInFinder(app: app) }
                    }
                }
            }
            .width(160)
        }
        .tableStyle(.inset)
    }

    private func regularAppsTable(useInspector: Bool) -> some View {
        Table(viewModel.filteredInstalledApps) {
            TableColumn("") { app in
                rowBackground(appID: app.id) {
                    if app.canUninstall {
                        Toggle("", isOn: Binding(
                            get: { viewModel.selectedInstalledAppIDs.contains(app.id) },
                            set: { isOn in
                                if isOn { viewModel.selectedInstalledAppIDs.insert(app.id) }
                                else { viewModel.selectedInstalledAppIDs.remove(app.id) }
                            })
                        )
                        .labelsHidden()
                    } else {
                        Image(systemName: app.isSystemApp ? "lock.shield.fill" : "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(28)

            TableColumn("apps.table.app".localized) { app in
                rowBackground(appID: app.id) { Text(app.name) }
            }

            TableColumn("apps.table.bundle".localized) { app in
                rowBackground(appID: app.id) {
                    Text(app.bundleID ?? "-").foregroundStyle(.secondary)
                }
            }

            TableColumn("apps.table.location".localized) { app in
                rowBackground(appID: app.id) {
                    Text(app.location).lineLimit(1).truncationMode(.middle)
                }
            }

            TableColumn("apps.table.type".localized) { app in
                rowBackground(appID: app.id) {
                    Text(app.typeDescription).foregroundStyle(.secondary)
                }
            }
            .width(100)

            TableColumn("apps.table.modified".localized) { app in
                rowBackground(appID: app.id) {
                    Text(app.modifiedDateText).foregroundStyle(.secondary)
                }
            }
            .width(110)

            TableColumn("apps.table.operation".localized) { app in
                rowBackground(appID: app.id) {
                    HStack(spacing: 8) {
                        Button("apps.btn.details".localized) { openDetails(for: app, useInspector: useInspector) }
                        Button("common.finder_app".localized) { viewModel.revealInFinder(app: app) }
                    }
                }
            }
            .width(160)
        }
        .tableStyle(.inset)
    }

    private var inspectorPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                relatedFilesSection
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
        }
    }

    private var relatedFilesSection: some View {
        Group {
            if let selected = viewModel.selectedApp {
                VStack(alignment: .leading, spacing: 8) {
                    Text("apps.details.selected".localized).font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(selected.name)
                                .font(.subheadline)
                                .bold()

                            if let bid = selected.bundleID {
                                Text(bid)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            if let modifiedDate = selected.modifiedDate {
                                Text("apps.details.modified".localized(with: modifiedDate.formatted(date: .abbreviated, time: .omitted)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(selected.appPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .cornerRadius(8)

                    HStack(spacing: 10) {
                        relatedSummaryChip(titleKey: "apps.related.total_count", value: "\(viewModel.relatedItems.count)")
                        relatedSummaryChip(titleKey: "apps.related.total_size", value: viewModel.totalRelatedSizeText)
                        relatedSummaryChip(titleKey: "apps.related.selected", value: "\(viewModel.selectedRelatedCount)")
                        relatedSummaryChip(titleKey: "apps.related.selected_size", value: viewModel.selectedRelatedSizeText)
                    }

                    if let current = viewModel.installedApps.first(where: { $0.id == selected.appPath }), current.isAppStoreApp {
                        Label("apps.details.appstore_note".localized, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if viewModel.userLibraryFolderURL == nil {
                        Text("apps.details.library_guide".localized)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if viewModel.isScanning {
                        HStack { ProgressView(); Text("apps.details.scanning".localized); Spacer() }
                    } else if viewModel.relatedItems.isEmpty {
                        Text("apps.details.no_related".localized)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("apps.details.found_count".localized(with: viewModel.relatedItems.count))
                            .font(.headline)

                        Table(viewModel.relatedItems) {
                            TableColumn("") { item in
                                Toggle("", isOn: binding(for: item)).labelsHidden()
                            }
                            .width(24)

                            TableColumn("apps.related.path".localized) { item in
                                Text(item.path).lineLimit(1).truncationMode(.middle)
                            }

                            TableColumn("apps.related.type".localized) { item in
                                Text(item.isDirectory ? "apps.related.folder".localized : "apps.related.file".localized)
                                    .foregroundStyle(.secondary)
                            }
                            .width(90)

                            TableColumn("apps.related.size".localized) { item in
                                Text(item.sizeText).foregroundStyle(.secondary)
                            }
                            .width(110)
                        }
                        .tableStyle(.inset)
                        .frame(minHeight: 260, maxHeight: .infinity)

                        HStack {
                            Text("apps.related.footer".localized(with: viewModel.selectedRelatedCount, viewModel.selectedRelatedSizeText))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("apps.details.trash_selected".localized) {
                                activeAlert = .removeRelatedFiles
                            }
                            .disabled(viewModel.isRemoving || viewModel.selectedRelatedCount == 0)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("apps.details.selected".localized).font(.headline)
                    Text("apps.details.guide".localized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func openDetails(for app: AppsInstalledApp, useInspector: Bool) {
        viewModel.analyzeInstalledApp(app: app)
        if !useInspector {
            showCompactDetailsSheet = true
        }
    }

    private func makeAlert(_ alert: AppsActiveAlert) -> Alert {
        switch alert {
        case .uninstallApps:
            let count = viewModel.deletableSelectedApps.count
            let summary = "apps.alert.uninstall.msg".localized(with: count, viewModel.selectedAppsCount)
            return Alert(
                title: Text("apps.alert.uninstall.title".localized),
                message: Text(summary),
                primaryButton: .destructive(Text("common.trash".localized)) {
                    viewModel.uninstallSelectedInstalledApps { nextAlert in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.activeAlert = nextAlert
                        }
                    }
                },
                secondaryButton: .cancel(Text("common.cancel".localized))
            )

        case .uninstallPartialFail(_, let failed):
            let names = viewModel.failedAppNamesForAlert()
            let namesLine = names.isEmpty ? "" : "apps.alert.fail.list".localized(with: names)

            return Alert(
                title: Text("apps.alert.fail.title".localized),
                message: Text("apps.alert.fail.msg".localized(with: failed, namesLine)),
                primaryButton: .default(Text("common.finder".localized)) {
                    viewModel.revealFailedApps()
                },
                secondaryButton: .cancel(Text("common.close".localized))
            )

        case .removeRelatedFiles:
            let count = viewModel.selectedRelatedCount
            let sizeText = viewModel.selectedRelatedSizeText
            return Alert(
                title: Text("apps.alert.related.title".localized),
                message: Text("apps.alert.related.msg".localized(with: count, sizeText)),
                primaryButton: .destructive(Text("common.trash".localized)) {
                    viewModel.removeSelectedRelatedItems()
                },
                secondaryButton: .cancel(Text("common.cancel".localized))
            )

        case .resetPermissions:
            return Alert(
                title: Text("apps.alert.reset.title".localized),
                message: Text("apps.alert.reset.msg".localized),
                primaryButton: .destructive(Text("common.clear".localized)) { viewModel.resetPermissions() },
                secondaryButton: .cancel(Text("common.cancel".localized))
            )
        }
    }

    private func binding(for item: AppsRelatedItem) -> Binding<Bool> {
        Binding(
            get: { viewModel.relatedItems.first(where: { $0.id == item.id })?.selected ?? false },
            set: { newValue in
                if let idx = viewModel.relatedItems.firstIndex(where: { $0.id == item.id }) {
                    viewModel.relatedItems[idx].selected = newValue
                }
            }
        )
    }

    @ViewBuilder
    private func rowBackground<Content: View>(appID: String, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, 2)
            .background((hoveredAppID == appID) ? Color.accentColor.opacity(0.08) : Color.clear)
            .onHover { inside in
                if inside { hoveredAppID = appID }
                else if hoveredAppID == appID { hoveredAppID = nil }
            }
    }

    private func appsSummaryCard(titleKey: String, value: String, icon: String) -> some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleKey.localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.headline)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func relatedSummaryChip(titleKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titleKey.localized)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Preview

#Preview {
    AppsView()
}
