//
//  StorageView.swift
//  TriClean
//
//  Created by changyu Kang on 08/12/2025.
//

import SwiftUI
import AppKit
import StoreKit // ✅ 결제 기능을 위해 추가
import os.log

private let storageLogger = Logger(subsystem: "com.nicechann.TriClean", category: "Storage")

// MARK: - Disk Usage (사용자 선택 기반) : Security-scoped bookmarks

private enum StorageDiskScopeBookmarkKey: String {
    case homeFolder = "TriClean.Storage.DiskUsage.HomeFolderBookmark"
    case applicationsFolders = "TriClean.Storage.DiskUsage.ApplicationsFolderBookmarks"
}

private struct StorageDiskScopeBookmarks {
    static func save(url: URL, for key: StorageDiskScopeBookmarkKey) {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key.rawValue)
        } catch {
            storageLogger.error("Bookmark save failed: \(key.rawValue, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
    }
    
    static func loadURL(for key: StorageDiskScopeBookmarkKey) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            if isStale { save(url: url, for: key) }
            return url
        } catch {
            storageLogger.error("Bookmark load failed: \(key.rawValue, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    static func clear(_ key: StorageDiskScopeBookmarkKey) {
        UserDefaults.standard.removeObject(forKey: key.rawValue)
    }
    
    // 복수 폴더 (/Applications + ~/Applications 등) 저장/복원
    static func save(urls: [URL], for key: StorageDiskScopeBookmarkKey) {
        do {
            let normalized = Array(Set(urls.map { $0.standardizedFileURL }))
                .sorted { $0.path < $1.path }
            
            let datas = try normalized.map { url in
                try url.bookmarkData(options: [.withSecurityScope],
                                     includingResourceValuesForKeys: nil,
                                     relativeTo: nil)
            }
            
            let blob = try PropertyListEncoder().encode(datas)
            UserDefaults.standard.set(blob, forKey: key.rawValue)
        } catch {
            storageLogger.error("Bookmarks save(many) failed: \(key.rawValue, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
    }
    
    static func loadURLs(for key: StorageDiskScopeBookmarkKey) -> [URL] {
        guard let blob = UserDefaults.standard.data(forKey: key.rawValue) else { return [] }
        do {
            let datas = try PropertyListDecoder().decode([Data].self, from: blob)
            var urls: [URL] = []
            var hasStaleBookmark = false
            urls.reserveCapacity(datas.count)
            
            for data in datas {
                var isStale = false
                if let url = try? URL(resolvingBookmarkData: data,
                                      options: [.withSecurityScope, .withoutUI],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) {
                    urls.append(url.standardizedFileURL)
                    hasStaleBookmark = hasStaleBookmark || isStale
                }
            }
            
            let uniqueURLs = Array(Set(urls)).sorted { $0.path < $1.path }
            if hasStaleBookmark { save(urls: uniqueURLs, for: key) }
            return uniqueURLs
        } catch {
            storageLogger.error("Bookmarks load(many) failed: \(key.rawValue, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

private struct StorageSecurityScopedAccessToken {
    private let url: URL
    private let started: Bool
    
    init(_ url: URL) {
        self.url = url
        self.started = url.startAccessingSecurityScopedResource()
    }
    
    func stop() {
        guard started else { return }
        url.stopAccessingSecurityScopedResource()
    }
}


// MARK: - 스캔 결과 모델 (폴더 + 파일)

struct FolderInfo: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let sizeBytes: Int64
    let isDirectory: Bool
    
    /// Table에서 "하위 항목처럼" 보이기 위한 들여쓰기 깊이
    /// - 0: 루트의 직계 결과(폴더/파일)
    /// - 1+: 폴더 하위로 표시되는 파일(현재는 1단계)
    let depth: Int
    
    /// depth > 0 인 경우, 어떤 상위 폴더 아래에 붙는지(표시/삭제 동기화용)
    let parentURL: URL?
    
    nonisolated init(url: URL, sizeBytes: Int64, isDirectory: Bool, depth: Int = 0, parentURL: URL? = nil) {
        self.url = url
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.depth = depth
        self.parentURL = parentURL
    }
    
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    
    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - Disk Info 모델

struct DiskInfo {
    let name: String
    let totalBytes: Int64
    let freeBytes: Int64
    let usedBytes: Int64
    
    /// 디스크 표기(예전 빨간 박스 UI와 유사하게 GB/Decimal 기준으로 표시)
    private func formatDisk(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB]
        f.countStyle = .decimal
        return f.string(fromByteCount: bytes)
    }
    
    var totalString: String { formatDisk(totalBytes) }
    var freeString: String  { formatDisk(freeBytes) }
    var usedString: String  { formatDisk(usedBytes) }
    
    var usedRatio: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}


// MARK: - Disk Usage Summary (분할 막대)

private struct DiskUsageCategory: Identifiable {
    let id = UUID()
    let name: String
    let bytes: Int64
    let color: Color
}

private struct DiskUsageSummaryView: View {
    let info: DiskInfo
    let homeBytes: Int64?
    let appsBytes: Int64?
    let isHomeSelected: Bool
    let isAppsSelected: Bool
    let isDetailScanning: Bool
    
    private struct LegendItem: Identifiable {
        let id = UUID()
        let name: String
        let bytes: Int64
        let color: Color
        let note: String?
        let isPlaceholder: Bool
    }
    
    private var usedTotal: Int64 {
        max(Int64(0), info.usedBytes)
    }
    
    private var totalCapacity: Int64 {
        max(Int64(1), info.totalBytes)
    }
    
    private var homeUsed: Int64 {
        guard isHomeSelected else { return 0 }
        return min(max(homeBytes ?? 0, 0), usedTotal)
    }
    
    private var appsUsed: Int64 {
        guard isAppsSelected else { return 0 }
        // Home이 잡아먹은 만큼 제외하고 clamp
        return min(max(appsBytes ?? 0, 0), max(usedTotal - homeUsed, 0))
    }
    
    private var otherUsed: Int64 {
        max(usedTotal - homeUsed - appsUsed, 0)
    }
    
    private var freeBytes: Int64 {
        max(min(info.freeBytes, totalCapacity), 0)
    }
    
    // 막대에 실제로 칠하는 구간(0은 제외)
    private var barCategories: [DiskUsageCategory] {
        var result: [DiskUsageCategory] = []
        if homeUsed > 0 {
            result.append(.init(name: "storage.legend.home".localized, bytes: homeUsed, color: Color(red: 0.98, green: 0.46, blue: 0.33)))
        }
        if appsUsed > 0 {
            result.append(.init(name: "storage.legend.apps".localized, bytes: appsUsed, color: Color(red: 0.99, green: 0.77, blue: 0.30)))
        }
        if otherUsed > 0 {
            result.append(.init(name: "storage.legend.other".localized, bytes: otherUsed, color: Color(red: 0.35, green: 0.70, blue: 0.90)))
        }
        if freeBytes > 0 {
            result.append(.init(name: "storage.legend.free".localized, bytes: freeBytes, color: Color.gray.opacity(0.60)))
        }
        return result
    }
    
    // 범례는 항상 4개(미선택은 placeholder)
    private var legendItems: [LegendItem] {
        [
            .init(
                name: "storage.legend.home".localized,
                bytes: homeUsed,
                color: Color(red: 0.98, green: 0.46, blue: 0.33),
                note: isHomeSelected ? nil : "(\("common.permission_needed".localized))",
                isPlaceholder: !isHomeSelected
            ),
            .init(
                name: "storage.legend.apps".localized,
                bytes: appsUsed,
                color: Color(red: 0.99, green: 0.77, blue: 0.30),
                note: isAppsSelected ? nil : "(\("common.permission_needed".localized))",
                isPlaceholder: !isAppsSelected
            ),
            .init(
                name: "storage.legend.other".localized,
                bytes: otherUsed,
                color: Color(red: 0.35, green: 0.70, blue: 0.90),
                note: nil,
                isPlaceholder: false
            ),
            .init(
                name: "storage.legend.free".localized,
                bytes: freeBytes,
                color: Color.gray.opacity(0.60),
                note: nil,
                isPlaceholder: false
            )
        ]
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(info.name)
                    .font(.headline)
                Spacer()
                Text("storage.usage.format".localized(with: info.usedString, info.totalString))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            GeometryReader { geo in
                let width = geo.size.width
                let total = totalCapacity
                
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.35))
                        .frame(height: 18)
                    
                    HStack(spacing: 0) {
                        ForEach(barCategories) { cat in
                            let ratio = Double(cat.bytes) / Double(total)
                            Rectangle()
                                .fill(cat.color)
                                .frame(width: max(1, width * ratio), height: 18)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    
                    // 오른쪽 Free 용량 라벨(예전 UI 느낌)
                    HStack {
                        Spacer()
                        Text(info.freeString)
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .frame(width: width)
                }
            }
            .frame(height: 22)
            
            if isDetailScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("storage.msg.analyzing_home_apps".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            HStack(spacing: 16) {
                ForEach(legendItems) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.color)
                            .opacity(item.isPlaceholder ? 0.25 : 1.0)
                            .frame(width: 8, height: 8)
                        
                        HStack(spacing: 4) {
                            Text(item.name)
                            if let note = item.note {
                                Text(note)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(item.isPlaceholder ? .secondary : .primary)
                    }
                }
            }
            .font(.caption)
        }
    }
}

// MARK: - StorageView

struct StorageView: View {

    // 구매 상태 연결
    @EnvironmentObject private var storeManager: StoreManager

    // ✅ [공유 모델] 앱 레벨에서 주입된 동일 인스턴스를 사용 (SmartScan과 상태 공유)
    @EnvironmentObject private var junkViewModel: JunkScannerViewModel

    // ✅ Paywall 표시 여부
    @State private var showPaywall = false

    // 디스크 정보 + 상세 카테고리 정보
    @State private var diskInfo: DiskInfo? = nil
    @State private var homeScopeURL: URL? = StorageDiskScopeBookmarks.loadURL(for: .homeFolder)
    @State private var appsScopeURLs: [URL] = StorageDiskScopeBookmarks.loadURLs(for: .applicationsFolders)

    @State private var homeFolderBytes: Int64? = nil
    @State private var appsFolderBytes: Int64? = nil
    @State private var isHomeScanning: Bool = false
    @State private var isAppsScanning: Bool = false

    var body: some View {
        // ✅ 인셋 규칙을 고정(섹션 간 좌우 정렬 깨짐 방지)
        let outerPadding: CGFloat = 16
        let sectionInset: CGFloat = 12

        // ✅ 본문은 스크롤 가능, 배너는 safeAreaInset으로 하단에 고정
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                diskHeaderSection

                JunkSectionView(viewModel: junkViewModel, onUpgradeRequired: { showPaywall = true })
                    .padding(.horizontal, sectionInset)

                Spacer(minLength: 10)
            }
            .padding(.horizontal, outerPadding)
            .padding(.top, outerPadding)
            // 배너가 있을 때 본문이 배너에 가리지 않도록 충분한 하단 여백 확보
            .padding(.bottom, storeManager.isPurchased ? outerPadding : 110)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            if !storeManager.isPurchased {
                Divider()
                UpgradeBottomBanner(onBuyTap: { showPaywall = true })
                .frame(maxWidth: .infinity)
                // ✅ 상단 섹션(디스크 카드 내부 12pt 인셋)과 동일한 좌우 정렬
                .padding(.horizontal, outerPadding + sectionInset)
                .padding(.vertical, 10)
                // 배너 영역은 불투명 배경으로 하단 프레임/스크롤 컨텐츠와 분리
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
        .onAppear {
            loadDiskInfo()

            if junkViewModel.libraryURL != nil && !junkViewModel.hasResults && !junkViewModel.isScanning {
                junkViewModel.scan()
            }

            // ✅ 보수적: 권한(선택)이 있는 경우에만 사용량 계산
            if homeScopeURL != nil {
                scanHomeFolder()
            }
            if !appsScopeURLs.isEmpty {
                scanApplicationsFolder()
            }
        }
    }

    // MARK: - UI Sections

    private var diskHeaderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("storage.header".localized)
                .font(.title2.bold())

            if let diskInfo {
                DiskUsageSummaryView(
                    info: diskInfo,
                    homeBytes: homeFolderBytes,
                    appsBytes: appsFolderBytes,
                    isHomeSelected: homeScopeURL != nil,
                    isAppsSelected: !appsScopeURLs.isEmpty,
                    isDetailScanning: isHomeScanning || isAppsScanning
                )

                diskUsageScopeControls
            } else {
                Text("storage.loading".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var diskUsageScopeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: homeScopeURL == nil ? "xmark.circle" : "checkmark.circle")
                    .foregroundStyle(homeScopeURL == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("storage.legend.home".localized)
                        .font(.caption.bold())
                    Text(homeScopeURL?.path ?? "storage.scope.home_needed".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(homeScopeURL == nil ? "common.select".localized : "common.change".localized) {
                    selectHomeFolderForDiskUsage()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                if homeScopeURL != nil {
                    Button("common.clear".localized) { clearHomeFolderScope() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: appsScopeURLs.isEmpty ? "xmark.circle" : "checkmark.circle")
                    .foregroundStyle(appsScopeURLs.isEmpty ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("storage.legend.apps".localized)
                        .font(.caption.bold())
                    Text(appsScopeURLs.isEmpty ? "storage.scope.apps_needed".localized : appsScopeURLs.map { $0.path }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(appsScopeURLs.isEmpty ? "common.select".localized : "common.change".localized) {
                    selectApplicationsFoldersForDiskUsage()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                if !appsScopeURLs.isEmpty {
                    Button("common.clear".localized) { clearApplicationsFoldersScope() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                }
            }

            Text("storage.scope.guide".localized)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    // MARK: - Disk Info

    private func loadDiskInfo() {
        // "/"보다는 현재 사용자 볼륨 기준이 UI(설정/파인더)와 더 일관적인 경우가 많습니다.
        let volumeURL = FileManager.default.homeDirectoryForCurrentUser

        do {
            let values = try volumeURL.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])

            guard let total = values.volumeTotalCapacity else {
                diskInfo = nil
                return
            }

            let free: Int64 =
            values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)

            let name = values.volumeName ?? "Macintosh HD"
            let totalBytes = Int64(total)
            let freeBytes = max(Int64(0), min(free, totalBytes))
            let usedBytes = max(Int64(0), totalBytes - freeBytes)

            diskInfo = DiskInfo(
                name: name,
                totalBytes: totalBytes,
                freeBytes: freeBytes,
                usedBytes: usedBytes
            )
        } catch {
            diskInfo = nil
        }
    }

    // MARK: - Folder Size Scans (Home / Applications)

    private func scanHomeFolder() {
        // ✅ 사용자 선택(보안 스코프) 기반: 선택되지 않으면 미표시(nil)
        guard let homeURL = homeScopeURL else {
            homeFolderBytes = nil
            isHomeScanning = false
            return
        }

        isHomeScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let token = StorageSecurityScopedAccessToken(homeURL)
            defer { token.stop() }

            let size = Self.folderSizeBytes(at: homeURL)

            DispatchQueue.main.async {
                self.homeFolderBytes = size
                self.isHomeScanning = false
            }
        }
    }

    private func scanApplicationsFolder() {
        // ✅ 사용자 선택(보안 스코프) 기반: 선택된 폴더들만 합산
        guard !appsScopeURLs.isEmpty else {
            appsFolderBytes = nil
            isAppsScanning = false
            return
        }

        let targets = appsScopeURLs.map { $0.standardizedFileURL }

        isAppsScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            var total: Int64 = 0
            for url in targets {
                let token = StorageSecurityScopedAccessToken(url)
                total += Self.folderSizeBytes(at: url)
                token.stop()
            }

            DispatchQueue.main.async {
                self.appsFolderBytes = total
                self.isAppsScanning = false
            }
        }
    }

    // MARK: - Disk Usage Scope (사용자 선택 기반)

    private func selectHomeFolderForDiskUsage() {
        let panel = NSOpenPanel()
        panel.title = "storage.scope.select_home_title".localized
        panel.message = "storage.scope.select_home_msg".localized
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        if panel.runModal() == .OK, let url = panel.url {
            StorageDiskScopeBookmarks.save(url: url, for: .homeFolder)
            homeScopeURL = url.standardizedFileURL
            homeFolderBytes = nil
            scanHomeFolder()
        }
    }

    private func selectApplicationsFoldersForDiskUsage() {
        let panel = NSOpenPanel()
        panel.title = "storage.scope.select_apps_title".localized
        panel.message = "storage.scope.select_apps_msg".localized
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        if panel.runModal() == .OK {
            let urls = panel.urls.map { $0.standardizedFileURL }
            StorageDiskScopeBookmarks.save(urls: urls, for: .applicationsFolders)
            appsScopeURLs = urls
            appsFolderBytes = nil
            scanApplicationsFolder()
        }
    }

    private func clearHomeFolderScope() {
        StorageDiskScopeBookmarks.clear(.homeFolder)
        homeScopeURL = nil
        homeFolderBytes = nil
        isHomeScanning = false
    }

    private func clearApplicationsFoldersScope() {
        StorageDiskScopeBookmarks.clear(.applicationsFolders)
        appsScopeURLs = []
        appsFolderBytes = nil
        isAppsScanning = false
    }

    // MARK: - Size Utilities

    private static func folderSizeBytes(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey]

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0

        // Swift 6: DirectoryEnumerator의 for-in 순회는 async 컨텍스트에서 makeIterator() 이슈가 날 수 있으므로
        // nextObject() 기반으로 순회
        while let fileURL = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }

            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }

        return total
    }
}
