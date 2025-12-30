//
//  AppsView.swift
//  TriClean
//
//  Created by changyu Kang on 08/12/2025.
//

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

// @unchecked Sendable 적용 및 init을 nonisolated로 선언
private final class AppsScopedAccessToken: @unchecked Sendable {
    private let url: URL
    private let started: Bool

    nonisolated init?(url: URL) {
        self.url = url
        self.started = url.startAccessingSecurityScopedResource()
        if !started { return nil }
    }

    deinit {
        if started {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

// MARK: - Models

struct AppsInstalledApp: Identifiable, Hashable, Sendable {
    let name: String
    let bundleID: String?
    let url: URL
    let canUninstall: Bool
    let isSystemApp: Bool
    
    // 미리 계산된 문자열 저장
    let id: String
    let location: String

    var typeDescription: String {
        if isSystemApp { return "시스템 앱" }
        return canUninstall ? "사용자 앱" : "보호됨"
    }
    
    nonisolated init(name: String, bundleID: String?, url: URL, canUninstall: Bool, isSystemApp: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.url = url
        self.canUninstall = canUninstall
        self.isSystemApp = isSystemApp
        self.id = url.path(percentEncoded: false)
        self.location = url.deletingLastPathComponent().path(percentEncoded: false)
    }
}

struct AppsRelatedItem: Identifiable, Hashable, Sendable {
    let url: URL
    var selected: Bool
    let isDirectory: Bool
    
    let id: String
    let path: String
    let name: String
    
    nonisolated init(url: URL, selected: Bool, isDirectory: Bool) {
        self.url = url
        self.selected = selected
        self.isDirectory = isDirectory
        
        let rawPath = url.path(percentEncoded: false)
        self.id = rawPath
        self.path = rawPath
        self.name = url.lastPathComponent
    }
}

struct AppsSelectedAppInfo: Sendable {
    let name: String
    let bundleID: String?
    let appPath: String
}

enum AppsActiveAlert: Identifiable {
    case uninstallApps
    case removeRelatedFiles
    case resetPermissions

    var id: Int {
        switch self {
        case .uninstallApps: return 1
        case .removeRelatedFiles: return 2
        case .resetPermissions: return 3
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

    // 상세/관련 파일
    @Published var selectedApp: AppsSelectedAppInfo?
    @Published var relatedItems: [AppsRelatedItem] = []

    // 상태
    @Published var isLoadingInstalledApps: Bool = false
    @Published var isScanning: Bool = false
    @Published var isRemoving: Bool = false
    @Published var lastStatusMessage: String?
    @Published var lastStatusIsError: Bool = false

    init() {
        applicationsFolderURL = AppsSecurityScopedBookmarks.load(key: .applicationsFolder)
        userLibraryFolderURL  = AppsSecurityScopedBookmarks.load(key: .userLibraryFolder)
        manualAppBundleURL    = AppsSecurityScopedBookmarks.load(key: .manualAppBundle)
    }

    // MARK: - Derived

    var filteredInstalledApps: [AppsInstalledApp] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return installedApps }
        let lower = q.lowercased()
        return installedApps.filter { app in
            app.name.lowercased().contains(lower)
            || (app.bundleID?.lowercased().contains(lower) ?? false)
            || app.id.lowercased().contains(lower)
        }
    }

    var selectedInstalledApps: [AppsInstalledApp] {
        installedApps.filter { selectedInstalledAppIDs.contains($0.id) }
    }

    var deletableSelectedApps: [AppsInstalledApp] {
        selectedInstalledApps.filter { $0.canUninstall }
    }

    var uninstallButtonHelpText: String {
        if isRemoving { return "앱 삭제 작업이 진행 중입니다." }

        let selected = selectedInstalledApps.count
        let deletable = deletableSelectedApps.count

        if selected == 0 { return "삭제할 앱을 먼저 선택해 주세요." }
        if deletable == 0 { return "선택된 앱은 모두 시스템/보호 앱이거나 현재 권한 범위에서 삭제할 수 없습니다." }
        if deletable < selected { return "선택된 앱 중 일부만 삭제 가능합니다. 삭제 가능한 앱만 휴지통으로 이동됩니다." }
        return "선택한 앱 번들을 휴지통으로 이동합니다."
    }

    // MARK: - User Choice: Scope selection

    func selectApplicationsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Applications 폴더 선택"
        panel.message = "설치 앱 목록을 구성할 폴더를 선택하세요. (예: /Applications 또는 ~/Applications)\n선택한 폴더 범위 안에서만 TriClean이 앱 목록을 스캔합니다."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try AppsSecurityScopedBookmarks.save(url: url, key: .applicationsFolder)
                applicationsFolderURL = url
                lastStatusIsError = false
                lastStatusMessage = "Applications 폴더를 선택했습니다: \(url.path)"
                loadInstalledApps()
            } catch {
                lastStatusIsError = true
                lastStatusMessage = "폴더 권한(북마크) 저장에 실패했습니다: \(error.localizedDescription)"
            }
        }
    }

    func selectUserLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Home Library(~/Library) 선택"
        panel.message = "관련 파일(Preferences/Caches/Containers 등) 분석 범위를 지정합니다.\n선택한 Home Library 범위 안에서만 TriClean이 관련 파일을 탐지/삭제합니다."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try AppsSecurityScopedBookmarks.save(url: url, key: .userLibraryFolder)
                userLibraryFolderURL = url
                lastStatusIsError = false
                lastStatusMessage = "Home Library를 선택했습니다: \(url.path)"
            } catch {
                lastStatusIsError = true
                lastStatusMessage = "폴더 권한(북마크) 저장에 실패했습니다: \(error.localizedDescription)"
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

        lastStatusIsError = false
        lastStatusMessage = "선택 권한을 초기화했습니다. 다시 폴더를 선택해 주세요."
    }

    // MARK: - Manual app selection (.app)

    func selectAppBundleManually() {
        let panel = NSOpenPanel()
        panel.title = "앱 선택"
        panel.message = "TriClean이 분석/삭제 대상으로 사용할 .app 번들을 직접 선택합니다.\n(선택한 앱 번들 범위 안에서만 접근 가능)"
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
                lastStatusMessage = "앱 권한(북마크) 저장에 실패했습니다: \(error.localizedDescription)"
            }
        }
    }

    private func handleManuallySelectedApp(at appURL: URL) {
        guard let token = AppsScopedAccessToken(url: appURL) else {
            lastStatusIsError = true
            lastStatusMessage = "선택한 앱 번들의 접근 권한을 시작할 수 없습니다. 다시 선택해 주세요."
            return
        }
        _ = token

        // 이미 목록에 있는지 확인
        if let existing = installedApps.first(where: { $0.url.standardizedFileURL == appURL.standardizedFileURL }) {
            selectedInstalledAppIDs = [existing.id]
            searchText = ""
            analyzeInstalledApp(app: existing)
            return
        }

        // 목록에 없으면 새로 생성해서 추가
        if let app = buildInstalledAppOnMain(from: appURL) {
            installedApps.append(app)
            installedApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            
            selectedInstalledAppIDs = [app.id]
            searchText = ""
            analyzeInstalledApp(app: app)

            lastStatusIsError = false
            lastStatusMessage = "앱을 직접 선택했습니다: \(appURL.path)"
        } else {
            lastStatusIsError = true
            lastStatusMessage = "선택한 항목에서 앱 정보를 읽지 못했습니다."
        }
    }

    // MARK: - Load Installed Apps

    func loadInstalledApps() {
        guard let root = applicationsFolderURL else {
            lastStatusIsError = true
            lastStatusMessage = "권한 필요: 먼저 Applications 폴더를 선택해 주세요."
            installedApps = []
            selectedInstalledAppIDs = []
            selectedApp = nil
            relatedItems = []
            return
        }

        guard let token = AppsScopedAccessToken(url: root) else {
            lastStatusIsError = true
            lastStatusMessage = "Applications 폴더 접근 권한을 시작할 수 없습니다. 다시 선택해 주세요."
            return
        }

        isLoadingInstalledApps = true
        lastStatusIsError = false
        lastStatusMessage = nil

        Task {
            let scanned = await self.scanAppsNonRecursive(in: root)
            
            self.installedApps = scanned.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            
            if self.installedApps.isEmpty {
                self.lastStatusIsError = false
                self.lastStatusMessage = "선택한 폴더에서 .app을 찾지 못했습니다."
            } else {
                self.lastStatusIsError = false
                self.lastStatusMessage = "설치 앱 \(self.installedApps.count)개를 불러왔습니다."
            }
            
            self.isLoadingInstalledApps = false
            
            let existingIDs = Set(self.installedApps.map(\.id))
            self.selectedInstalledAppIDs = self.selectedInstalledAppIDs.intersection(existingIDs)
            
            _ = token
        }
    }

    nonisolated private func scanAppsNonRecursive(in dir: URL) async -> [AppsInstalledApp] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }

        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var apps: [AppsInstalledApp] = []
        for url in contents where url.pathExtension.lowercased() == "app" {
            if let app = buildInstalledAppWithoutBundle(from: url) {
                apps.append(app)
            }
        }
        return apps
    }
    
    private func buildInstalledAppOnMain(from url: URL) -> AppsInstalledApp? {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier
        return makeAppModel(url: url, name: name, bundleID: bundleID)
    }

    nonisolated private func buildInstalledAppWithoutBundle(from url: URL) -> AppsInstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        var name: String?
        var bundleID: String?
        
        if FileManager.default.fileExists(atPath: plistURL.path),
           let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            name = plist["CFBundleName"] as? String
            bundleID = plist["CFBundleIdentifier"] as? String
        }
        
        let finalName = name ?? url.deletingPathExtension().lastPathComponent
        return makeAppModel(url: url, name: finalName, bundleID: bundleID)
    }
    
    nonisolated private func makeAppModel(url: URL, name: String, bundleID: String?) -> AppsInstalledApp {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        let canDelete = fm.isDeletableFile(atPath: url.path) && fm.isWritableFile(atPath: parent.path)
        let isSystemPath = url.path.hasPrefix("/System/Applications")
        let isApple = bundleID?.hasPrefix("com.apple.") ?? false
        let isSystemApp = isSystemPath || (isApple && !canDelete)

        return AppsInstalledApp(name: name, bundleID: bundleID, url: url, canUninstall: canDelete, isSystemApp: isSystemApp)
    }

    // MARK: - Details Scan

    func analyzeInstalledApp(app: AppsInstalledApp) {
        analyzeInstalledApp(url: app.url)
    }

    private func analyzeInstalledApp(url appURL: URL) {
        let bundle = Bundle(url: appURL)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let bundleID = bundle?.bundleIdentifier

        selectedApp = AppsSelectedAppInfo(name: name, bundleID: bundleID, appPath: appURL.path)
        relatedItems = []

        guard userLibraryFolderURL != nil else {
            lastStatusIsError = false
            lastStatusMessage = "관련 파일 분석을 하려면 먼저 Home Library(~/Library)를 선택해 주세요."
            return
        }

        scanRelatedFiles(for: name, bundleID: bundleID)
    }

    private func scanRelatedFiles(for appName: String, bundleID: String?) {
        guard let libraryRoot = userLibraryFolderURL else { return }

        guard let token = AppsScopedAccessToken(url: libraryRoot) else {
            isScanning = false
            lastStatusIsError = true
            lastStatusMessage = "Home Library 접근 권한을 시작할 수 없습니다. 다시 선택해 주세요."
            return
        }

        isScanning = true
        lastStatusIsError = false
        lastStatusMessage = nil

        Task {
            let found = await self.collectRelatedItems(in: libraryRoot, appName: appName, bundleID: bundleID)
            
            self.relatedItems = found
            self.isScanning = false

            if found.isEmpty {
                self.lastStatusIsError = false
                self.lastStatusMessage = "관련 파일을 찾지 못했습니다."
            } else {
                self.lastStatusIsError = false
                self.lastStatusMessage = "관련 파일 \(found.count)개를 찾았습니다."
            }
            _ = token
        }
    }

    nonisolated private func collectRelatedItems(in libraryRoot: URL, appName: String, bundleID: String?) async -> [AppsRelatedItem] {
        let fm = FileManager.default
        let candidateSubfolders: [(String, Int)] = [
            ("Preferences", 1), ("Containers", 1), ("Application Support", 2), ("Caches", 2)
        ]

        var keys: [String] = []
        if let bundleID = bundleID, !bundleID.isEmpty {
            let lower = bundleID.lowercased()
            keys.append(lower)
            if let last = bundleID.split(separator: ".").last {
                keys.append(String(last).lowercased())
            }
        }
        keys.append(appName.lowercased())

        func hits(_ name: String) -> Bool {
            let lower = name.lowercased()
            return keys.contains { lower.contains($0) }
        }

        var results: [AppsRelatedItem] = []
        var seen = Set<String>()

        for (sub, depth) in candidateSubfolders {
            let base = libraryRoot.appendingPathComponent(sub, isDirectory: true)
            guard fm.fileExists(atPath: base.path) else { continue }

            var queue: [(URL, Int)] = [(base, 0)]
            while let (current, d) = queue.first {
                queue.removeFirst()
                if d > depth { continue }

                guard let contents = try? fm.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }

                for url in contents {
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                    let isDir = values?.isDirectory ?? false
                    let name = url.lastPathComponent

                    if hits(name) {
                        let id = url.path
                        if !seen.contains(id) {
                            seen.insert(id)
                            results.append(AppsRelatedItem(url: url, selected: true, isDirectory: isDir))
                        }
                    }

                    if isDir && (d + 1) <= depth {
                        queue.append((url, d + 1))
                    }
                }
            }
        }
        return results.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    // MARK: - Uninstall

    func revealInFinder(app: AppsInstalledApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    func uninstallSelectedInstalledApps() {
        let targets = deletableSelectedApps
        guard !targets.isEmpty else {
            lastStatusIsError = true
            lastStatusMessage = "휴지통으로 이동할 수 있는 앱이 없습니다."
            return
        }

        isRemoving = true
        lastStatusMessage = nil
        lastStatusIsError = false

        var tokens: [AppsScopedAccessToken] = []
        if let root = applicationsFolderURL, let t = AppsScopedAccessToken(url: root) { tokens.append(t) }
        if let manual = manualAppBundleURL, let t = AppsScopedAccessToken(url: manual) { tokens.append(t) }

        Task {
            let ok = await self.performUninstall(targets: targets)
            
            self.isRemoving = false

            if ok.isEmpty {
                self.lastStatusIsError = true
                self.lastStatusMessage = "선택한 앱을 휴지통으로 이동하지 못했습니다."
            } else {
                let names = ok.map(\.name).joined(separator: ", ")
                self.lastStatusIsError = false
                self.lastStatusMessage = "앱 \(ok.count)개(\(names))을 휴지통으로 이동했습니다."

                let okIDs = Set(ok.map(\.id))
                self.installedApps.removeAll { okIDs.contains($0.id) }
                self.selectedInstalledAppIDs.subtract(okIDs)

                if let selected = self.selectedApp, okIDs.contains(selected.appPath) {
                    self.selectedApp = nil
                    self.relatedItems = []
                }
            }
            _ = tokens
        }
    }
    
    nonisolated private func performUninstall(targets: [AppsInstalledApp]) async -> [AppsInstalledApp] {
        let fm = FileManager.default
        var ok: [AppsInstalledApp] = []
        for app in targets {
            let itemToken = AppsScopedAccessToken(url: app.url)
            do {
                var resultingURL: NSURL?
                try fm.trashItem(at: app.url, resultingItemURL: &resultingURL)
                ok.append(app)
            } catch {
                print("앱 휴지통 이동 실패: \(app.url.path) - \(error)")
            }
            _ = itemToken
        }
        return ok
    }

    func removeSelectedRelatedItems() {
        let targets = relatedItems.filter { $0.selected }
        guard !targets.isEmpty else { return }
        guard let libraryRoot = userLibraryFolderURL, let rootToken = AppsScopedAccessToken(url: libraryRoot) else { return }

        isRemoving = true
        lastStatusMessage = nil

        Task {
            let count = await self.performRelatedRemoval(targets: targets)
            self.isRemoving = false
            if count > 0 {
                self.lastStatusIsError = false
                self.lastStatusMessage = "선택한 \(count)개 항목을 휴지통으로 이동했습니다."
                let removedIDs = Set(targets.map(\.id))
                self.relatedItems.removeAll { removedIDs.contains($0.id) }
            } else {
                self.lastStatusIsError = true
                self.lastStatusMessage = "휴지통으로 이동할 수 있는 항목이 없습니다."
            }
            _ = rootToken
        }
    }
    
    nonisolated private func performRelatedRemoval(targets: [AppsRelatedItem]) async -> Int {
        let fm = FileManager.default
        var count = 0
        for item in targets {
            let itemToken = AppsScopedAccessToken(url: item.url)
            do {
                var resultingURL: NSURL?
                try fm.trashItem(at: item.url, resultingItemURL: &resultingURL)
                count += 1
            } catch {
                print("관련 파일 휴지통 이동 실패: \(item.url.path) - \(error)")
            }
            _ = itemToken
        }
        return count
    }
}

// MARK: - View

struct AppsView: View {
    @StateObject private var viewModel = AppsViewModel()
    @State private var activeAlert: AppsActiveAlert?
    @State private var hoveredAppID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ✅ 상단: layoutPriority(1)을 주어 공간 부족 시에도 잘리지 않도록 보호
            GroupBox {
                VStack(spacing: 10) {
                    // Row 1: Applications Folder
                    HStack(spacing: 12) {
                        Image(systemName: viewModel.applicationsFolderURL == nil ? "xmark.circle" : "checkmark.circle")
                            .font(.title2)
                            .foregroundStyle(viewModel.applicationsFolderURL == nil ? Color.secondary : Color.green)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Installed Apps 목록")
                                .font(.subheadline).bold()
                            Text(viewModel.applicationsFolderURL?.path ?? "권한 필요: Applications 폴더를 선택해 주세요.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        
                        Spacer()
                        
                        Button("Applications 폴더 선택…") {
                            viewModel.selectApplicationsFolder()
                        }
                    }

                    Divider()

                    // Row 2: Library Folder
                    HStack(spacing: 12) {
                        Image(systemName: viewModel.userLibraryFolderURL == nil ? "xmark.circle" : "checkmark.circle")
                            .font(.title2)
                            .foregroundStyle(viewModel.userLibraryFolderURL == nil ? Color.secondary : Color.green)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("관련 파일 분석(캐시/Preferences)")
                                .font(.subheadline).bold()
                            Text(viewModel.userLibraryFolderURL?.path ?? "권한 필요: Home Library(~/Library) 폴더를 선택해 주세요.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        
                        Spacer()
                        
                        Button("Home Library 선택…") {
                            viewModel.selectUserLibraryFolder()
                        }
                    }

                    // Row 3: Actions
                    HStack(spacing: 8) {
                        Button {
                            viewModel.loadInstalledApps()
                        } label: {
                            Label("Scan", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.applicationsFolderURL == nil || viewModel.isLoadingInstalledApps || viewModel.isRemoving)
                        
                        Spacer()
                        
                        Button("권한 초기화…") {
                            activeAlert = .resetPermissions
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(4)
            }
            .layoutPriority(1) // ✅ 핵심: 상단 영역이 압축되지 않도록 우선순위 높임

            // 헤더
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("App Uninstall")
                        .font(.title).bold()
                    Text("선택한 폴더/앱 범위 안에서만 목록을 스캔하고, 사용자가 선택한 항목만 휴지통으로 이동합니다. macOS 시스템/보호 앱은 App Store 버전 TriClean에서 직접 삭제할 수 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("앱 파일 직접 선택…") {
                    viewModel.selectAppBundleManually()
                }
            }

            // 검색 + Uninstall
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("앱 이름 또는 Bundle ID 검색", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(.quaternary)
                .cornerRadius(8)

                Spacer()

                Button("Uninstall") {
                    activeAlert = .uninstallApps
                }
                .frame(width: 88)
                .disabled(viewModel.deletableSelectedApps.isEmpty || viewModel.isRemoving)
                .help(viewModel.uninstallButtonHelpText)
            }

            // 설치 앱 테이블
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.isLoadingInstalledApps {
                        HStack { ProgressView(); Text("설치된 앱 목록을 불러오는 중…"); Spacer() }
                    } else if viewModel.applicationsFolderURL == nil {
                        Text("먼저 상단에서 Applications 폴더를 선택한 뒤 Scan을 눌러 주세요.")
                            .foregroundStyle(.secondary)
                    } else if viewModel.filteredInstalledApps.isEmpty {
                        Text("표시할 앱이 없습니다. (검색 조건/선택 폴더를 확인해 주세요)")
                            .foregroundStyle(.secondary)
                    } else {
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

                            TableColumn("App") { app in
                                rowBackground(appID: app.id) { Text(app.name) }
                            }

                            TableColumn("Bundle ID") { app in
                                rowBackground(appID: app.id) {
                                    Text(app.bundleID ?? "-").foregroundStyle(.secondary)
                                }
                            }

                            TableColumn("Location") { app in
                                rowBackground(appID: app.id) {
                                    Text(app.location).lineLimit(1).truncationMode(.middle)
                                }
                            }

                            TableColumn("Type") { app in
                                rowBackground(appID: app.id) {
                                    Text(app.typeDescription).foregroundStyle(.secondary)
                                }
                            }
                            .width(90)

                            TableColumn("Operation") { app in
                                rowBackground(appID: app.id) {
                                    HStack(spacing: 8) {
                                        Button("Details") { viewModel.analyzeInstalledApp(app: app) }
                                        Button("Finder") { viewModel.revealInFinder(app: app) }
                                    }
                                }
                            }
                            .width(150)
                        }
                        .tableStyle(.inset)
                        // ✅ maxHeight: .infinity를 주어 공간이 부족하면 줄어들고, 남으면 늘어나게 변경
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    Spacer(minLength: 0)
                }
                // ✅ minHeight를 낮춰서(100) 하단 뷰가 올라와도 테이블이 찌그러지며 공존하도록 함
                .frame(maxWidth: .infinity, minHeight: 100, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
            } label: {
                Text("Installed Apps").font(.headline)
            }

            // 상태 메시지
            if let status = viewModel.lastStatusMessage {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(viewModel.lastStatusIsError ? .red : .secondary)
            }

            Divider().padding(.vertical, 4)

            // Related
            if let selected = viewModel.selectedApp {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected App").font(.headline)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(selected.name)
                            .font(.subheadline)
                            .bold()
                        
                        if let bid = selected.bundleID {
                            Text(bid)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Text(selected.appPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .padding(8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .cornerRadius(8)

                    if viewModel.userLibraryFolderURL == nil {
                        Text("관련 파일 분석을 하려면 상단에서 Home Library(~/Library)를 선택해 주세요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if viewModel.isScanning {
                        HStack { ProgressView(); Text("관련 파일 검색 중…"); Spacer() }
                    } else if viewModel.relatedItems.isEmpty {
                        Text("관련 파일이 없거나 찾지 못했습니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("관련 파일 (\(viewModel.relatedItems.count))")
                            .font(.headline)

                        Table(viewModel.relatedItems) {
                            TableColumn("") { item in
                                Toggle("", isOn: binding(for: item)).labelsHidden()
                            }
                            .width(24)

                            TableColumn("Path") { item in
                                Text(item.path).lineLimit(1).truncationMode(.middle)
                            }

                            TableColumn("Type") { item in
                                Text(item.isDirectory ? "Folder" : "File").foregroundStyle(.secondary)
                            }
                            .width(80)
                        }
                        .tableStyle(.inset)
                        .frame(minHeight: 160) // 관련 파일 목록은 고정 최소 높이 유지

                        HStack {
                            Button("선택 항목 휴지통으로 이동") {
                                activeAlert = .removeRelatedFiles
                            }
                            .disabled(viewModel.isRemoving || viewModel.relatedItems.allSatisfy { !$0.selected })

                            Spacer()
                        }
                    }
                }
            } else {
                Text("테이블에서 앱을 선택해 ‘Details’를 누르거나, 상단의 ‘앱 파일 직접 선택…’ 버튼으로 앱을 지정하면 관련 파일을 분석합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .uninstallApps:
                let count = viewModel.deletableSelectedApps.count
                return Alert(
                    title: Text("선택한 앱 삭제"),
                    message: Text("선택한 \(count)개 앱 번들을 휴지통으로 이동합니다. 관련 파일은 아래 리스트에서 별도로 선택해 정리할 수 있습니다."),
                    primaryButton: .destructive(Text("Uninstall")) { viewModel.uninstallSelectedInstalledApps() },
                    secondaryButton: .cancel()
                )

            case .removeRelatedFiles:
                let count = viewModel.relatedItems.filter { $0.selected }.count
                return Alert(
                    title: Text("관련 파일 삭제"),
                    message: Text("선택한 \(count)개 관련 파일/폴더를 휴지통으로 이동하시겠습니까?"),
                    primaryButton: .destructive(Text("Move to Trash")) { viewModel.removeSelectedRelatedItems() },
                    secondaryButton: .cancel()
                )

            case .resetPermissions:
                return Alert(
                    title: Text("권한 초기화"),
                    message: Text("선택한 폴더/앱 권한(북마크)을 초기화합니다. 이후 다시 폴더를 선택해야 스캔/삭제가 가능합니다."),
                    primaryButton: .destructive(Text("초기화")) { viewModel.resetPermissions() },
                    secondaryButton: .cancel()
                )
            }
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
}

// MARK: - Preview

#Preview {
    AppsView()
}

// xxx_org
//import SwiftUI
//import Combine
//import AppKit
//import UniformTypeIdentifiers
//
//// MARK: - AppsView 전용 Security-Scoped Bookmark 유틸
//
//private enum AppsBookmarkKey: String {
//    case applicationsFolder = "TriClean.Apps.Bookmark.ApplicationsFolder"
//    case userLibraryFolder  = "TriClean.Apps.Bookmark.UserLibraryFolder"
//    case manualAppBundle    = "TriClean.Apps.Bookmark.ManualAppBundle"
//}
//
//private enum AppsSecurityScopedBookmarks {
//    static func save(url: URL, key: AppsBookmarkKey) throws {
//        let data = try url.bookmarkData(
//            options: [.withSecurityScope],
//            includingResourceValuesForKeys: nil,
//            relativeTo: nil
//        )
//        UserDefaults.standard.set(data, forKey: key.rawValue)
//    }
//
//    static func load(key: AppsBookmarkKey) -> URL? {
//        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
//        var stale = false
//        do {
//            let url = try URL(
//                resolvingBookmarkData: data,
//                options: [.withSecurityScope, .withoutUI],
//                relativeTo: nil,
//                bookmarkDataIsStale: &stale
//            )
//            if stale { try? save(url: url, key: key) }
//            return url
//        } catch {
//            return nil
//        }
//    }
//
//    static func clear(key: AppsBookmarkKey) {
//        UserDefaults.standard.removeObject(forKey: key.rawValue)
//    }
//}
//
//// ✅ 수정: @unchecked Sendable 적용 및 init을 nonisolated로 선언
//private final class AppsScopedAccessToken: @unchecked Sendable {
//    private let url: URL
//    private let started: Bool
//
//    // 백그라운드 스레드에서 생성 가능하도록 nonisolated 명시
//    nonisolated init?(url: URL) {
//        self.url = url
//        self.started = url.startAccessingSecurityScopedResource()
//        if !started { return nil }
//    }
//
//    deinit {
//        if started {
//            url.stopAccessingSecurityScopedResource()
//        }
//    }
//}
//
//// MARK: - Models
//
//struct AppsInstalledApp: Identifiable, Hashable, Sendable {
//    let name: String
//    let bundleID: String?
//    let url: URL
//    let canUninstall: Bool
//    let isSystemApp: Bool
//    
//    // 미리 계산된 문자열 저장
//    let id: String
//    let location: String
//
//    var typeDescription: String {
//        if isSystemApp { return "시스템 앱" }
//        return canUninstall ? "사용자 앱" : "보호됨"
//    }
//    
//    // ✅ 수정: 백그라운드 생성을 위해 nonisolated 명시
//    nonisolated init(name: String, bundleID: String?, url: URL, canUninstall: Bool, isSystemApp: Bool) {
//        self.name = name
//        self.bundleID = bundleID
//        self.url = url
//        self.canUninstall = canUninstall
//        self.isSystemApp = isSystemApp
//        self.id = url.path(percentEncoded: false)
//        self.location = url.deletingLastPathComponent().path(percentEncoded: false)
//    }
//}
//
//struct AppsRelatedItem: Identifiable, Hashable, Sendable {
//    let url: URL
//    var selected: Bool
//    let isDirectory: Bool
//    
//    let id: String
//    let path: String
//    let name: String
//    
//    // ✅ 수정: 백그라운드 생성을 위해 nonisolated 명시
//    nonisolated init(url: URL, selected: Bool, isDirectory: Bool) {
//        self.url = url
//        self.selected = selected
//        self.isDirectory = isDirectory
//        
//        let rawPath = url.path(percentEncoded: false)
//        self.id = rawPath
//        self.path = rawPath
//        self.name = url.lastPathComponent
//    }
//}
//
//struct AppsSelectedAppInfo: Sendable {
//    let name: String
//    let bundleID: String?
//    let appPath: String
//}
//
//enum AppsActiveAlert: Identifiable {
//    case uninstallApps
//    case removeRelatedFiles
//    case resetPermissions
//
//    var id: Int {
//        switch self {
//        case .uninstallApps: return 1
//        case .removeRelatedFiles: return 2
//        case .resetPermissions: return 3
//        }
//    }
//}
//
//// MARK: - ViewModel
//
//@MainActor
//final class AppsViewModel: ObservableObject {
//
//    // 사용자 선택 범위
//    @Published private(set) var applicationsFolderURL: URL?
//    @Published private(set) var userLibraryFolderURL: URL?
//    @Published private(set) var manualAppBundleURL: URL?
//
//    // 목록/선택
//    @Published var installedApps: [AppsInstalledApp] = []
//    @Published var selectedInstalledAppIDs: Set<String> = []
//    @Published var searchText: String = ""
//
//    // 상세/관련 파일
//    @Published var selectedApp: AppsSelectedAppInfo?
//    @Published var relatedItems: [AppsRelatedItem] = []
//
//    // 상태
//    @Published var isLoadingInstalledApps: Bool = false
//    @Published var isScanning: Bool = false
//    @Published var isRemoving: Bool = false
//    @Published var lastStatusMessage: String?
//    @Published var lastStatusIsError: Bool = false
//
//    init() {
//        applicationsFolderURL = AppsSecurityScopedBookmarks.load(key: .applicationsFolder)
//        userLibraryFolderURL  = AppsSecurityScopedBookmarks.load(key: .userLibraryFolder)
//        manualAppBundleURL    = AppsSecurityScopedBookmarks.load(key: .manualAppBundle)
//    }
//
//    // MARK: - Derived
//
//    var filteredInstalledApps: [AppsInstalledApp] {
//        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
//        guard !q.isEmpty else { return installedApps }
//        let lower = q.lowercased()
//        return installedApps.filter { app in
//            app.name.lowercased().contains(lower)
//            || (app.bundleID?.lowercased().contains(lower) ?? false)
//            || app.id.lowercased().contains(lower)
//        }
//    }
//
//    var selectedInstalledApps: [AppsInstalledApp] {
//        installedApps.filter { selectedInstalledAppIDs.contains($0.id) }
//    }
//
//    var deletableSelectedApps: [AppsInstalledApp] {
//        selectedInstalledApps.filter { $0.canUninstall }
//    }
//
//    var uninstallButtonHelpText: String {
//        if isRemoving { return "앱 삭제 작업이 진행 중입니다." }
//
//        let selected = selectedInstalledApps.count
//        let deletable = deletableSelectedApps.count
//
//        if selected == 0 { return "삭제할 앱을 먼저 선택해 주세요." }
//        if deletable == 0 { return "선택된 앱은 모두 시스템/보호 앱이거나 현재 권한 범위에서 삭제할 수 없습니다." }
//        if deletable < selected { return "선택된 앱 중 일부만 삭제 가능합니다. 삭제 가능한 앱만 휴지통으로 이동됩니다." }
//        return "선택한 앱 번들을 휴지통으로 이동합니다."
//    }
//
//    // MARK: - User Choice: Scope selection
//
//    func selectApplicationsFolder() {
//        let panel = NSOpenPanel()
//        panel.title = "Applications 폴더 선택"
//        panel.message = "설치 앱 목록을 구성할 폴더를 선택하세요. (예: /Applications 또는 ~/Applications)\n선택한 폴더 범위 안에서만 TriClean이 앱 목록을 스캔합니다."
//        panel.allowsMultipleSelection = false
//        panel.canChooseDirectories = true
//        panel.canChooseFiles = false
//        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
//
//        if panel.runModal() == .OK, let url = panel.url {
//            do {
//                try AppsSecurityScopedBookmarks.save(url: url, key: .applicationsFolder)
//                applicationsFolderURL = url
//                lastStatusIsError = false
//                lastStatusMessage = "Applications 폴더를 선택했습니다: \(url.path)"
//                loadInstalledApps()
//            } catch {
//                lastStatusIsError = true
//                lastStatusMessage = "폴더 권한(북마크) 저장에 실패했습니다: \(error.localizedDescription)"
//            }
//        }
//    }
//
//    func selectUserLibraryFolder() {
//        let panel = NSOpenPanel()
//        panel.title = "Home Library(~/Library) 선택"
//        panel.message = "관련 파일(Preferences/Caches/Containers 등) 분석 범위를 지정합니다.\n선택한 Home Library 범위 안에서만 TriClean이 관련 파일을 탐지/삭제합니다."
//        panel.allowsMultipleSelection = false
//        panel.canChooseDirectories = true
//        panel.canChooseFiles = false
//        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
//
//        if panel.runModal() == .OK, let url = panel.url {
//            do {
//                try AppsSecurityScopedBookmarks.save(url: url, key: .userLibraryFolder)
//                userLibraryFolderURL = url
//                lastStatusIsError = false
//                lastStatusMessage = "Home Library를 선택했습니다: \(url.path)"
//            } catch {
//                lastStatusIsError = true
//                lastStatusMessage = "폴더 권한(북마크) 저장에 실패했습니다: \(error.localizedDescription)"
//            }
//        }
//    }
//
//    func resetPermissions() {
//        AppsSecurityScopedBookmarks.clear(key: .applicationsFolder)
//        AppsSecurityScopedBookmarks.clear(key: .userLibraryFolder)
//        AppsSecurityScopedBookmarks.clear(key: .manualAppBundle)
//
//        applicationsFolderURL = nil
//        userLibraryFolderURL = nil
//        manualAppBundleURL = nil
//
//        installedApps = []
//        selectedInstalledAppIDs = []
//        selectedApp = nil
//        relatedItems = []
//
//        lastStatusIsError = false
//        lastStatusMessage = "선택 권한을 초기화했습니다. 다시 폴더를 선택해 주세요."
//    }
//
//    // MARK: - Manual app selection (.app)
//
//    func selectAppBundleManually() {
//        let panel = NSOpenPanel()
//        panel.title = "앱 선택"
//        panel.message = "TriClean이 분석/삭제 대상으로 사용할 .app 번들을 직접 선택합니다.\n(선택한 앱 번들 범위 안에서만 접근 가능)"
//        panel.allowsMultipleSelection = false
//        panel.canChooseDirectories = false
//        panel.canChooseFiles = true
//        panel.allowedContentTypes = [.applicationBundle]
//        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
//
//        if panel.runModal() == .OK, let url = panel.url {
//            do {
//                try AppsSecurityScopedBookmarks.save(url: url, key: .manualAppBundle)
//                manualAppBundleURL = url
//                handleManuallySelectedApp(at: url)
//            } catch {
//                lastStatusIsError = true
//                lastStatusMessage = "앱 권한(북마크) 저장에 실패했습니다: \(error.localizedDescription)"
//            }
//        }
//    }
//
//    private func handleManuallySelectedApp(at appURL: URL) {
//        guard let token = AppsScopedAccessToken(url: appURL) else {
//            lastStatusIsError = true
//            lastStatusMessage = "선택한 앱 번들의 접근 권한을 시작할 수 없습니다. 다시 선택해 주세요."
//            return
//        }
//        _ = token
//
//        if let existing = installedApps.first(where: { $0.url.standardizedFileURL == appURL.standardizedFileURL }) {
//            selectedInstalledAppIDs = [existing.id]
//            analyzeInstalledApp(app: existing)
//            return
//        }
//
//        if let app = buildInstalledAppOnMain(from: appURL) {
//            installedApps.append(app)
//            installedApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
//            selectedInstalledAppIDs = [app.id]
//            analyzeInstalledApp(app: app)
//
//            lastStatusIsError = false
//            lastStatusMessage = "앱을 직접 선택했습니다: \(appURL.path)"
//        } else {
//            lastStatusIsError = true
//            lastStatusMessage = "선택한 항목에서 앱 정보를 읽지 못했습니다."
//        }
//    }
//
//    // MARK: - Load Installed Apps
//
//    func loadInstalledApps() {
//        guard let root = applicationsFolderURL else {
//            lastStatusIsError = true
//            lastStatusMessage = "권한 필요: 먼저 Applications 폴더를 선택해 주세요."
//            installedApps = []
//            selectedInstalledAppIDs = []
//            selectedApp = nil
//            relatedItems = []
//            return
//        }
//
//        guard let token = AppsScopedAccessToken(url: root) else {
//            lastStatusIsError = true
//            lastStatusMessage = "Applications 폴더 접근 권한을 시작할 수 없습니다. 다시 선택해 주세요."
//            return
//        }
//
//        isLoadingInstalledApps = true
//        lastStatusIsError = false
//        lastStatusMessage = nil
//
//        Task {
//            let scanned = await self.scanAppsNonRecursive(in: root)
//            
//            self.installedApps = scanned.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
//            
//            if self.installedApps.isEmpty {
//                self.lastStatusIsError = false
//                self.lastStatusMessage = "선택한 폴더에서 .app을 찾지 못했습니다."
//            } else {
//                self.lastStatusIsError = false
//                self.lastStatusMessage = "설치 앱 \(self.installedApps.count)개를 불러왔습니다."
//            }
//            
//            self.isLoadingInstalledApps = false
//            
//            let existingIDs = Set(self.installedApps.map(\.id))
//            self.selectedInstalledAppIDs = self.selectedInstalledAppIDs.intersection(existingIDs)
//            
//            _ = token
//        }
//    }
//
//    nonisolated private func scanAppsNonRecursive(in dir: URL) async -> [AppsInstalledApp] {
//        let fm = FileManager.default
//        guard fm.fileExists(atPath: dir.path) else { return [] }
//
//        guard let contents = try? fm.contentsOfDirectory(
//            at: dir,
//            includingPropertiesForKeys: [.isDirectoryKey],
//            options: [.skipsHiddenFiles]
//        ) else { return [] }
//
//        var apps: [AppsInstalledApp] = []
//        for url in contents where url.pathExtension.lowercased() == "app" {
//            if let app = buildInstalledAppWithoutBundle(from: url) {
//                apps.append(app)
//            }
//        }
//        return apps
//    }
//    
//    private func buildInstalledAppOnMain(from url: URL) -> AppsInstalledApp? {
//        let bundle = Bundle(url: url)
//        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
//            ?? url.deletingPathExtension().lastPathComponent
//        let bundleID = bundle?.bundleIdentifier
//        return makeAppModel(url: url, name: name, bundleID: bundleID)
//    }
//
//    nonisolated private func buildInstalledAppWithoutBundle(from url: URL) -> AppsInstalledApp? {
//        let plistURL = url.appendingPathComponent("Contents/Info.plist")
//        var name: String?
//        var bundleID: String?
//        
//        if FileManager.default.fileExists(atPath: plistURL.path),
//           let data = try? Data(contentsOf: plistURL),
//           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
//            name = plist["CFBundleName"] as? String
//            bundleID = plist["CFBundleIdentifier"] as? String
//        }
//        
//        let finalName = name ?? url.deletingPathExtension().lastPathComponent
//        return makeAppModel(url: url, name: finalName, bundleID: bundleID)
//    }
//    
//    nonisolated private func makeAppModel(url: URL, name: String, bundleID: String?) -> AppsInstalledApp {
//        let fm = FileManager.default
//        let parent = url.deletingLastPathComponent()
//        let canDelete = fm.isDeletableFile(atPath: url.path) && fm.isWritableFile(atPath: parent.path)
//        let isSystemPath = url.path.hasPrefix("/System/Applications")
//        let isApple = bundleID?.hasPrefix("com.apple.") ?? false
//        let isSystemApp = isSystemPath || (isApple && !canDelete)
//
//        return AppsInstalledApp(name: name, bundleID: bundleID, url: url, canUninstall: canDelete, isSystemApp: isSystemApp)
//    }
//
//    // MARK: - Details Scan
//
//    func analyzeInstalledApp(app: AppsInstalledApp) {
//        analyzeInstalledApp(url: app.url)
//    }
//
//    private func analyzeInstalledApp(url appURL: URL) {
//        let bundle = Bundle(url: appURL)
//        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
//            ?? appURL.deletingPathExtension().lastPathComponent
//        let bundleID = bundle?.bundleIdentifier
//
//        selectedApp = AppsSelectedAppInfo(name: name, bundleID: bundleID, appPath: appURL.path)
//        relatedItems = []
//
//        guard userLibraryFolderURL != nil else {
//            lastStatusIsError = false
//            lastStatusMessage = "관련 파일 분석을 하려면 먼저 Home Library(~/Library)를 선택해 주세요."
//            return
//        }
//
//        scanRelatedFiles(for: name, bundleID: bundleID)
//    }
//
//    private func scanRelatedFiles(for appName: String, bundleID: String?) {
//        guard let libraryRoot = userLibraryFolderURL else { return }
//
//        guard let token = AppsScopedAccessToken(url: libraryRoot) else {
//            isScanning = false
//            lastStatusIsError = true
//            lastStatusMessage = "Home Library 접근 권한을 시작할 수 없습니다. 다시 선택해 주세요."
//            return
//        }
//
//        isScanning = true
//        lastStatusIsError = false
//        lastStatusMessage = nil
//
//        Task {
//            let found = await self.collectRelatedItems(in: libraryRoot, appName: appName, bundleID: bundleID)
//            
//            self.relatedItems = found
//            self.isScanning = false
//
//            if found.isEmpty {
//                self.lastStatusIsError = false
//                self.lastStatusMessage = "관련 파일을 찾지 못했습니다."
//            } else {
//                self.lastStatusIsError = false
//                self.lastStatusMessage = "관련 파일 \(found.count)개를 찾았습니다."
//            }
//            _ = token
//        }
//    }
//
//    nonisolated private func collectRelatedItems(in libraryRoot: URL, appName: String, bundleID: String?) async -> [AppsRelatedItem] {
//        let fm = FileManager.default
//        let candidateSubfolders: [(String, Int)] = [
//            ("Preferences", 1), ("Containers", 1), ("Application Support", 2), ("Caches", 2)
//        ]
//
//        var keys: [String] = []
//        if let bundleID = bundleID, !bundleID.isEmpty {
//            let lower = bundleID.lowercased()
//            keys.append(lower)
//            if let last = bundleID.split(separator: ".").last {
//                keys.append(String(last).lowercased())
//            }
//        }
//        keys.append(appName.lowercased())
//
//        func hits(_ name: String) -> Bool {
//            let lower = name.lowercased()
//            return keys.contains { lower.contains($0) }
//        }
//
//        var results: [AppsRelatedItem] = []
//        var seen = Set<String>()
//
//        for (sub, depth) in candidateSubfolders {
//            let base = libraryRoot.appendingPathComponent(sub, isDirectory: true)
//            guard fm.fileExists(atPath: base.path) else { continue }
//
//            var queue: [(URL, Int)] = [(base, 0)]
//            while let (current, d) = queue.first {
//                queue.removeFirst()
//                if d > depth { continue }
//
//                guard let contents = try? fm.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
//
//                for url in contents {
//                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
//                    let isDir = values?.isDirectory ?? false
//                    let name = url.lastPathComponent
//
//                    if hits(name) {
//                        let id = url.path
//                        if !seen.contains(id) {
//                            seen.insert(id)
//                            results.append(AppsRelatedItem(url: url, selected: true, isDirectory: isDir))
//                        }
//                    }
//
//                    if isDir && (d + 1) <= depth {
//                        queue.append((url, d + 1))
//                    }
//                }
//            }
//        }
//        return results.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
//    }
//
//    // MARK: - Uninstall
//
//    func revealInFinder(app: AppsInstalledApp) {
//        NSWorkspace.shared.activateFileViewerSelecting([app.url])
//    }
//
//    func uninstallSelectedInstalledApps() {
//        let targets = deletableSelectedApps
//        guard !targets.isEmpty else {
//            lastStatusIsError = true
//            lastStatusMessage = "휴지통으로 이동할 수 있는 앱이 없습니다."
//            return
//        }
//
//        isRemoving = true
//        lastStatusMessage = nil
//        lastStatusIsError = false
//
//        var tokens: [AppsScopedAccessToken] = []
//        if let root = applicationsFolderURL, let t = AppsScopedAccessToken(url: root) { tokens.append(t) }
//        if let manual = manualAppBundleURL, let t = AppsScopedAccessToken(url: manual) { tokens.append(t) }
//
//        Task {
//            let ok = await self.performUninstall(targets: targets)
//            
//            self.isRemoving = false
//
//            if ok.isEmpty {
//                self.lastStatusIsError = true
//                self.lastStatusMessage = "선택한 앱을 휴지통으로 이동하지 못했습니다."
//            } else {
//                let names = ok.map(\.name).joined(separator: ", ")
//                self.lastStatusIsError = false
//                self.lastStatusMessage = "앱 \(ok.count)개(\(names))을 휴지통으로 이동했습니다."
//
//                let okIDs = Set(ok.map(\.id))
//                self.installedApps.removeAll { okIDs.contains($0.id) }
//                self.selectedInstalledAppIDs.subtract(okIDs)
//
//                if let selected = self.selectedApp, okIDs.contains(selected.appPath) {
//                    self.selectedApp = nil
//                    self.relatedItems = []
//                }
//            }
//            _ = tokens
//        }
//    }
//    
//    nonisolated private func performUninstall(targets: [AppsInstalledApp]) async -> [AppsInstalledApp] {
//        let fm = FileManager.default
//        var ok: [AppsInstalledApp] = []
//        for app in targets {
//            let itemToken = AppsScopedAccessToken(url: app.url)
//            do {
//                var resultingURL: NSURL?
//                try fm.trashItem(at: app.url, resultingItemURL: &resultingURL)
//                ok.append(app)
//            } catch {
//                print("앱 휴지통 이동 실패: \(app.url.path) - \(error)")
//            }
//            _ = itemToken
//        }
//        return ok
//    }
//
//    func removeSelectedRelatedItems() {
//        let targets = relatedItems.filter { $0.selected }
//        guard !targets.isEmpty else { return }
//        guard let libraryRoot = userLibraryFolderURL, let rootToken = AppsScopedAccessToken(url: libraryRoot) else { return }
//
//        isRemoving = true
//        lastStatusMessage = nil
//
//        Task {
//            let count = await self.performRelatedRemoval(targets: targets)
//            self.isRemoving = false
//            if count > 0 {
//                self.lastStatusIsError = false
//                self.lastStatusMessage = "선택한 \(count)개 항목을 휴지통으로 이동했습니다."
//                let removedIDs = Set(targets.map(\.id))
//                self.relatedItems.removeAll { removedIDs.contains($0.id) }
//            } else {
//                self.lastStatusIsError = true
//                self.lastStatusMessage = "휴지통으로 이동할 수 있는 항목이 없습니다."
//            }
//            _ = rootToken
//        }
//    }
//    
//    nonisolated private func performRelatedRemoval(targets: [AppsRelatedItem]) async -> Int {
//        let fm = FileManager.default
//        var count = 0
//        for item in targets {
//            let itemToken = AppsScopedAccessToken(url: item.url)
//            do {
//                var resultingURL: NSURL?
//                try fm.trashItem(at: item.url, resultingItemURL: &resultingURL)
//                count += 1
//            } catch {
//                print("관련 파일 휴지통 이동 실패: \(item.url.path) - \(error)")
//            }
//            _ = itemToken
//        }
//        return count
//    }
//}
//
//// MARK: - View
//
//struct AppsView: View {
//    @StateObject private var viewModel = AppsViewModel()
//    @State private var activeAlert: AppsActiveAlert?
//    @State private var hoveredAppID: String? = nil
//
//    var body: some View {
//        VStack(alignment: .leading, spacing: 12) {
//            GroupBox {
//                VStack(alignment: .leading, spacing: 10) {
//                    HStack {
//                        Image(systemName: viewModel.applicationsFolderURL == nil ? "xmark.circle" : "checkmark.circle")
//                        VStack(alignment: .leading, spacing: 2) {
//                            Text("Installed Apps 목록")
//                                .font(.subheadline).bold()
//                            Text(viewModel.applicationsFolderURL?.path ?? "권한 필요: Applications 폴더를 선택해 주세요.")
//                                .font(.caption).foregroundStyle(.secondary)
//                        }
//                        Spacer()
//                        Button("Applications 폴더 선택…") { viewModel.selectApplicationsFolder() }
//                    }
//                    HStack {
//                        Image(systemName: viewModel.userLibraryFolderURL == nil ? "xmark.circle" : "checkmark.circle")
//                        VStack(alignment: .leading, spacing: 2) {
//                            Text("관련 파일 분석")
//                                .font(.subheadline).bold()
//                            Text(viewModel.userLibraryFolderURL?.path ?? "권한 필요: Home Library(~/Library) 폴더를 선택해 주세요.")
//                                .font(.caption).foregroundStyle(.secondary)
//                        }
//                        Spacer()
//                        Button("Home Library 선택…") { viewModel.selectUserLibraryFolder() }
//                    }
//                    HStack(spacing: 8) {
//                        Button { viewModel.loadInstalledApps() } label: { Label("Scan", systemImage: "arrow.clockwise") }
//                            .disabled(viewModel.applicationsFolderURL == nil || viewModel.isLoadingInstalledApps || viewModel.isRemoving)
//                        Spacer()
//                        Button("권한 초기화…") { activeAlert = .resetPermissions }
//                            .buttonStyle(.borderless).foregroundStyle(.secondary)
//                    }
//                    .font(.caption)
//                }
//            }
//
//            HStack(alignment: .center) {
//                VStack(alignment: .leading, spacing: 4) {
//                    Text("App Uninstall").font(.title).bold()
//                    Text("선택한 폴더/앱 범위 안에서만 목록을 스캔하고, 사용자가 선택한 항목만 휴지통으로 이동합니다.")
//                        .font(.caption).foregroundStyle(.secondary)
//                }
//                Spacer()
//                Button("앱 파일 직접 선택…") { viewModel.selectAppBundleManually() }
//            }
//
//            HStack(spacing: 12) {
//                HStack {
//                    Image(systemName: "magnifyingglass")
//                    TextField("앱 이름 또는 Bundle ID 검색", text: $viewModel.searchText).textFieldStyle(.plain)
//                }
//                .padding(6).background(.quaternary).cornerRadius(8)
//                Spacer()
//                Button("Uninstall") { activeAlert = .uninstallApps }
//                    .frame(width: 88)
//                    .disabled(viewModel.deletableSelectedApps.isEmpty || viewModel.isRemoving)
//                    .help(viewModel.uninstallButtonHelpText)
//            }
//
//            GroupBox {
//                VStack(alignment: .leading, spacing: 10) {
//                    if viewModel.isLoadingInstalledApps {
//                        HStack { ProgressView(); Text("설치된 앱 목록을 불러오는 중…"); Spacer() }
//                    } else if viewModel.applicationsFolderURL == nil {
//                        Text("먼저 상단에서 Applications 폴더를 선택한 뒤 Scan을 눌러 주세요.").foregroundStyle(.secondary)
//                    } else if viewModel.filteredInstalledApps.isEmpty {
//                        Text("표시할 앱이 없습니다.").foregroundStyle(.secondary)
//                    } else {
//                        Table(viewModel.filteredInstalledApps) {
//                            TableColumn("") { app in
//                                rowBackground(appID: app.id) {
//                                    if app.canUninstall {
//                                        Toggle("", isOn: Binding(
//                                            get: { viewModel.selectedInstalledAppIDs.contains(app.id) },
//                                            set: { isOn in
//                                                if isOn { viewModel.selectedInstalledAppIDs.insert(app.id) }
//                                                else { viewModel.selectedInstalledAppIDs.remove(app.id) }
//                                            })).labelsHidden()
//                                    } else {
//                                        Image(systemName: app.isSystemApp ? "lock.shield.fill" : "lock.fill").foregroundStyle(.secondary)
//                                    }
//                                }
//                            }.width(28)
//                            TableColumn("App") { app in rowBackground(appID: app.id) { Text(app.name) } }
//                            TableColumn("Bundle ID") { app in rowBackground(appID: app.id) { Text(app.bundleID ?? "-").foregroundStyle(.secondary) } }
//                            TableColumn("Location") { app in rowBackground(appID: app.id) { Text(app.location).lineLimit(1).truncationMode(.middle) } }
//                            TableColumn("Type") { app in rowBackground(appID: app.id) { Text(app.typeDescription).foregroundStyle(.secondary) } }.width(90)
//                            TableColumn("Operation") { app in
//                                rowBackground(appID: app.id) {
//                                    HStack(spacing: 8) {
//                                        Button("Details") { viewModel.analyzeInstalledApp(app: app) }
//                                        Button("Finder") { viewModel.revealInFinder(app: app) }
//                                    }
//                                }
//                            }.width(150)
//                        }
//                        .tableStyle(.inset)
//                        .frame(minHeight: 220)
//                    }
//                    Spacer(minLength: 0)
//                }
//                .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
//                .padding(8)
//            } label: { Text("Installed Apps").font(.headline) }
//
//            if let status = viewModel.lastStatusMessage {
//                Text(status).font(.footnote).foregroundStyle(viewModel.lastStatusIsError ? .red : .secondary)
//            }
//
//            Divider().padding(.vertical, 4)
//
//            if let selected = viewModel.selectedApp {
//                VStack(alignment: .leading, spacing: 8) {
//                    Text("Selected App").font(.headline)
//                    VStack(alignment: .leading, spacing: 2) {
//                        Text(selected.name).font(.subheadline).bold()
//                        if let bid = selected.bundleID { Text("Bundle ID: \(bid)").font(.caption).foregroundStyle(.secondary) }
//                        Text(selected.appPath).font(.caption2).foregroundStyle(.secondary)
//                    }
//                    .padding(8).background(Color(nsColor: .windowBackgroundColor)).cornerRadius(8)
//
//                    if viewModel.userLibraryFolderURL == nil {
//                        Text("관련 파일 분석을 하려면 상단에서 Home Library(~/Library)를 선택해 주세요.").font(.footnote).foregroundStyle(.secondary)
//                    } else if viewModel.isScanning {
//                        HStack { ProgressView(); Text("관련 파일 검색 중…"); Spacer() }
//                    } else if viewModel.relatedItems.isEmpty {
//                        Text("관련 파일이 없거나 찾지 못했습니다.").font(.footnote).foregroundStyle(.secondary)
//                    } else {
//                        Text("관련 파일 (\(viewModel.relatedItems.count))").font(.headline)
//                        Table(viewModel.relatedItems) {
//                            TableColumn("") { item in Toggle("", isOn: binding(for: item)).labelsHidden() }.width(24)
//                            TableColumn("Path") { item in Text(item.path).lineLimit(1).truncationMode(.middle) }
//                            TableColumn("Type") { item in Text(item.isDirectory ? "Folder" : "File").foregroundStyle(.secondary) }.width(80)
//                        }
//                        .tableStyle(.inset).frame(minHeight: 160)
//                        HStack {
//                            Button("선택 항목 휴지통으로 이동") { activeAlert = .removeRelatedFiles }
//                                .disabled(viewModel.isRemoving || viewModel.relatedItems.allSatisfy { !$0.selected })
//                            Spacer()
//                        }
//                    }
//                }
//            } else {
//                Text("테이블에서 앱을 선택해 ‘Details’를 누르거나, 상단의 ‘앱 파일 직접 선택…’ 버튼으로 앱을 지정하면 관련 파일을 분석합니다.").font(.footnote).foregroundStyle(.secondary)
//            }
//            Spacer(minLength: 0)
//        }
//        .padding()
//        .alert(item: $activeAlert) { alert in
//            switch alert {
//            case .uninstallApps:
//                return Alert(title: Text("선택한 앱 삭제"), message: Text("선택한 앱을 휴지통으로 이동합니다."), primaryButton: .destructive(Text("Uninstall")) { viewModel.uninstallSelectedInstalledApps() }, secondaryButton: .cancel())
//            case .removeRelatedFiles:
//                return Alert(title: Text("관련 파일 삭제"), message: Text("선택한 관련 파일을 휴지통으로 이동합니다."), primaryButton: .destructive(Text("Move to Trash")) { viewModel.removeSelectedRelatedItems() }, secondaryButton: .cancel())
//            case .resetPermissions:
//                return Alert(title: Text("권한 초기화"), message: Text("권한을 초기화합니다."), primaryButton: .destructive(Text("초기화")) { viewModel.resetPermissions() }, secondaryButton: .cancel())
//            }
//        }
//    }
//
//    private func binding(for item: AppsRelatedItem) -> Binding<Bool> {
//        Binding(
//            get: { viewModel.relatedItems.first(where: { $0.id == item.id })?.selected ?? false },
//            set: { newValue in
//                if let idx = viewModel.relatedItems.firstIndex(where: { $0.id == item.id }) { viewModel.relatedItems[idx].selected = newValue }
//            }
//        )
//    }
//
//    @ViewBuilder
//    private func rowBackground<Content: View>(appID: String, @ViewBuilder content: () -> Content) -> some View {
//        content().padding(.vertical, 2).background((hoveredAppID == appID) ? Color.accentColor.opacity(0.08) : Color.clear)
//            .onHover { inside in if inside { hoveredAppID = appID } else if hoveredAppID == appID { hoveredAppID = nil } }
//    }
//}
//
//#Preview {
//    AppsView()
//}
