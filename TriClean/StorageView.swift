//
//  StorageView.swift
//  TriClean
//
//  Created by changyu Kang on 08/12/2025.
//

import SwiftUI
import AppKit

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
            print("Bookmark save failed:", key.rawValue, error)
        }
    }

    static func loadURL(for key: StorageDiskScopeBookmarkKey) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
        var isStale = false
        do {
            return try URL(resolvingBookmarkData: data,
                           options: [.withSecurityScope, .withoutUI],
                           relativeTo: nil,
                           bookmarkDataIsStale: &isStale)
        } catch {
            print("Bookmark load failed:", key.rawValue, error)
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
            print("Bookmarks save(many) failed:", key.rawValue, error)
        }
    }

    static func loadURLs(for key: StorageDiskScopeBookmarkKey) -> [URL] {
        guard let blob = UserDefaults.standard.data(forKey: key.rawValue) else { return [] }
        do {
            let datas = try PropertyListDecoder().decode([Data].self, from: blob)
            var urls: [URL] = []
            urls.reserveCapacity(datas.count)

            for data in datas {
                var isStale = false
                if let url = try? URL(resolvingBookmarkData: data,
                                      options: [.withSecurityScope, .withoutUI],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) {
                    urls.append(url.standardizedFileURL)
                }
            }

            return Array(Set(urls)).sorted { $0.path < $1.path }
        } catch {
            print("Bookmarks load(many) failed:", key.rawValue, error)
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

struct FolderInfo: Identifiable, Hashable {
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

    init(url: URL, sizeBytes: Int64, isDirectory: Bool, depth: Int = 0, parentURL: URL? = nil) {
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
            result.append(.init(name: "Home Folder", bytes: homeUsed, color: Color(red: 0.98, green: 0.46, blue: 0.33)))
        }
        if appsUsed > 0 {
            result.append(.init(name: "Applications", bytes: appsUsed, color: Color(red: 0.99, green: 0.77, blue: 0.30)))
        }
        if otherUsed > 0 {
            result.append(.init(name: "Other Used", bytes: otherUsed, color: Color(red: 0.35, green: 0.70, blue: 0.90)))
        }
        if freeBytes > 0 {
            result.append(.init(name: "Free Space", bytes: freeBytes, color: Color.gray.opacity(0.60)))
        }
        return result
    }

    // 범례는 항상 4개(미선택은 placeholder)
    private var legendItems: [LegendItem] {
        [
            .init(
                name: "Home Folder",
                bytes: homeUsed,
                color: Color(red: 0.98, green: 0.46, blue: 0.33),
                note: isHomeSelected ? nil : "(권한 필요)",
                isPlaceholder: !isHomeSelected
            ),
            .init(
                name: "Applications",
                bytes: appsUsed,
                color: Color(red: 0.99, green: 0.77, blue: 0.30),
                note: isAppsSelected ? nil : "(권한 필요)",
                isPlaceholder: !isAppsSelected
            ),
            .init(
                name: "Other Used",
                bytes: otherUsed,
                color: Color(red: 0.35, green: 0.70, blue: 0.90),
                note: nil,
                isPlaceholder: false
            ),
            .init(
                name: "Free Space",
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
                Text("\(info.totalString) 중 \(info.usedString) 사용됨")
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
                    Text("Home/Applications 폴더 사용량 분석 중…")
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

    @State private var minFolderSizeMB: Double = 200
    @State private var selectedFolderURL: URL? = nil
    @State private var isScanning: Bool = false
    @State private var isAutoUpdating: Bool = false
    @State private var scanTask: Task<Void, Never>? = nil
    @State private var scanMessage: String =
        "스캔 결과가 없습니다. 상단의 'Select Folder & Scan' 버튼을 눌러 분석을 시작하세요."

    @State private var folderResults: [FolderInfo] = []
    @State private var ignoredFolderURLs: Set<URL> = []
    @State private var tableSelection = Set<FolderInfo.ID>()   // Table 선택 상태

    // 디스크 정보 + 상세 카테고리 정보
    @State private var diskInfo: DiskInfo? = nil
    @State private var homeScopeURL: URL? = StorageDiskScopeBookmarks.loadURL(for: .homeFolder)
    @State private var appsScopeURLs: [URL] = StorageDiskScopeBookmarks.loadURLs(for: .applicationsFolders)

    @State private var homeFolderBytes: Int64? = nil
    @State private var appsFolderBytes: Int64? = nil
    @State private var isHomeScanning: Bool = false
    @State private var isAppsScanning: Bool = false

    @State private var deleteTarget: FolderInfo? = nil    // 어떤 폴더를 지울지
    @State private var showingDeleteAlert = false        // 경고 다이얼로그 표시 여부

    @State private var activeScanID = UUID()
    @State private var lastScannedMinSizeMB: Double? = nil

    private var scanButtonBusyText: String {
        isAutoUpdating ? "Updating…" : "Scanning…"
    }

    private enum ScanTrigger {
        case manual
        case auto
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // 상단: 디스크 사용량
            diskHeaderSection

            Divider()

            // 폴더 스캔 섹션
            folderScanSection

            Divider()

            // 하단: 결과 테이블
            resultsTableSection

            Spacer(minLength: 10)
        }
        .padding()
        .padding(.top, 36)
        .onAppear {
            loadDiskInfo()

            // ✅ 보수적: 권한(선택)이 있는 경우에만 사용량 계산
            if homeScopeURL != nil {
                scanHomeFolder()
            }
            if !appsScopeURLs.isEmpty {
                scanApplicationsFolder()
            }
        }
        .task(id: minFolderSizeMB) {
            guard let url = selectedFolderURL else { return }

            // 디바운스: 슬라이더 드래그 중엔 잠깐 기다렸다가 1번만 실행
            try? await Task.sleep(nanoseconds: 250_000_000)

            // (선택) 같은 값으로 중복 재스캔 방지
            if lastScannedMinSizeMB == minFolderSizeMB { return }

            await MainActor.run {
                runScan(for: url, minSizeMB: minFolderSizeMB, trigger: .auto)
            }
        }
    }

    // MARK: - UI Sections

    private var diskHeaderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Disk Usage")
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
                Text("디스크 정보를 불러오는 중…")
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

    private func infoCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
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
                    Text("Home Folder")
                        .font(.caption.bold())
                    Text(homeScopeURL?.path ?? "권한 필요: Home 폴더를 선택해 주세요.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(homeScopeURL == nil ? "선택…" : "변경…") {
                    selectHomeFolderForDiskUsage()
                }
                if homeScopeURL != nil {
                    Button("해제") { clearHomeFolderScope() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: appsScopeURLs.isEmpty ? "xmark.circle" : "checkmark.circle")
                    .foregroundStyle(appsScopeURLs.isEmpty ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Applications")
                        .font(.caption.bold())
                    Text(appsScopeURLs.isEmpty ? "권한 필요: Applications 폴더를 선택해 주세요." : appsScopeURLs.map { $0.path }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(appsScopeURLs.isEmpty ? "선택…" : "변경…") {
                    selectApplicationsFoldersForDiskUsage()
                }
                if !appsScopeURLs.isEmpty {
                    Button("해제") { clearApplicationsFoldersScope() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }

            Text("※ Home/Applications 구간은 사용자가 선택한 폴더 범위에서만 계산됩니다. 선택하지 않으면 ‘Other Used’로만 표시됩니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private var folderScanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Disk Scan")
                    .font(.title3.bold())

                Spacer()

                Button {
                    selectFolderAndScan()
                } label: {
                    // ✅ 버튼 폭/높이 고정: 상태(Select/Scanning/Updating)에 따라 크기가 변하지 않도록
                    ZStack {
                        // size anchor (invisible) — 가장 큰 케이스(텍스트 + 스피너) 기준으로 고정
                        Group {
                            Text("Select Folder & Scan")
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Updating…")
                            }
                        }
                        .opacity(0)

                        if isScanning {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(scanButtonBusyText)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("Select Folder & Scan")
                                .lineLimit(1)
                        }
                    }
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(isScanning)
            }

            // 안내 문구
            Text("Tip: 시스템 폴더보다는 홈 폴더(~)/나 /Users 하위 폴더를 선택하는 것을 권장합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Min Folder Size")
                    .font(.subheadline)

                Slider(value: $minFolderSizeMB, in: 10...2000, step: 10)
                    .frame(maxWidth: 260)

                Text("\(Int(minFolderSizeMB)) MB+")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 90, alignment: .trailing)

                Spacer()
            }

            Text(scanMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var resultsTableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Results")
                    .font(.title3.bold())

                Spacer()

                Button(role: .destructive) {
                    deleteSelectedFolders()
                } label: {
                    Text("Move to Trash")
                }
                .disabled(isScanning || tableSelection.isEmpty)
            }

            Table(folderResults, selection: $tableSelection) {
                TableColumn("Item") { item in
                    let indent = CGFloat(item.depth) * 18

                    // 하위 파일은 "상위 폴더 기준 상대 경로"로 보이게(가독성)
                    let pathText: String = {
                        if let parent = item.parentURL {
                            let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
                            if item.path.hasPrefix(prefix) {
                                return String(item.path.dropFirst(prefix.count))
                            }
                        }
                        return item.path
                    }()

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            if item.depth > 0 {
                                Image(systemName: "arrow.turn.down.right")
                                    .foregroundStyle(.tertiary)
                            }

                            Image(systemName: item.isDirectory ? "folder" : "doc")
                                .foregroundStyle(.secondary)

                            Text(item.name)
                                .font(item.depth > 0 ? .subheadline : .body)
                                .foregroundStyle(item.depth > 0 ? .secondary : .primary)
                        }
                        .padding(.leading, indent)

                        Text(pathText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                TableColumn("Size") { item in
                    Text(item.sizeString)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 90, ideal: 110, max: 130)

                // Actions
                TableColumn("") { item in
                    Button {
                        openInFinder(item)
                    } label: {
                        Label("Finder", systemImage: "folder")
                    }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Reveal in Finder")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 90, ideal: 100, max: 110)

                TableColumn("") { item in
                    Button(role: .destructive) {
                        requestDelete(item)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(6)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Move to Trash")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 44, ideal: 48, max: 52)
            }            .frame(minHeight: 320)
            .alert("정말 삭제하시겠습니까?", isPresented: $showingDeleteAlert, presenting: deleteTarget) { _ in
                Button("휴지통으로 이동", role: .destructive) {
                    confirmDelete()
                }
                Button("취소", role: .cancel) {
                    deleteTarget = nil
                }
            } message: { target in
                Text("‘\(target.name)’ \(target.isDirectory ? "폴더" : "파일")를 휴지통으로 이동합니다. Finder에서 복원하거나 ‘휴지통 비우기’로 완전히 삭제할 수 있습니다.")
            }
        }
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
                defer { token.stop() }
                total += Self.folderSizeBytes(at: url)
            }

            DispatchQueue.main.async {
                self.appsFolderBytes = total
                self.isAppsScanning = false
            }
        }
    }

    // MARK: - Folder Scan

    // MARK: - Disk Usage Scope (사용자 선택 기반)

    private func selectHomeFolderForDiskUsage() {
        let panel = NSOpenPanel()
        panel.title = "Home Folder 선택"
        panel.message = "Disk Usage의 Home Folder 구간은 사용자가 선택한 폴더 범위에서만 계산됩니다."
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
        panel.title = "Applications 폴더 선택"
        panel.message = "Disk Usage의 Applications 구간 계산을 위해 폴더를 선택합니다. (/Applications, ~/Applications 등 복수 선택 가능)"
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


    private func selectFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            selectedFolderURL = url
            tableSelection.removeAll()

            runScan(for: url, minSizeMB: minFolderSizeMB, trigger: .manual)
        }
    }

    
private func runScan(for url: URL, minSizeMB: Double, trigger: ScanTrigger) {
    // ✅ 새로운 스캔이 시작되면 이전 스캔 Task를 취소(슬라이더 연속 변경/대용량 폴더에서 UI 멈춤 방지)
    scanTask?.cancel()

    let scanID = UUID()
    activeScanID = scanID

    let root = url.standardizedFileURL
    let ignoredSnapshot = ignoredFolderURLs   // 스캔 시작 시점 스냅샷
    let isAuto = (trigger == .auto)

    // 버튼 문구 분리용
    isAutoUpdating = isAuto
    isScanning = true
    tableSelection.removeAll()

    // 진행 문구
    switch trigger {
    case .manual:
        scanMessage = "'\(url.lastPathComponent)' 폴더를 분석 중입니다…"
    case .auto:
        scanMessage = "조건 변경으로 다시 분석 중입니다…"
    }

    // ✅ manual은 즉시 비우고 시작, auto는 첫 배치가 오기 전까지 기존 결과 유지(깜빡임 최소화)
    if trigger == .manual {
        folderResults = []
    }

    scanTask = Task(priority: .userInitiated) {
        // ✅ 선택 폴더에 대한 Security-Scoped 접근 시작/종료
        let token = StorageSecurityScopedAccessToken(root)
        defer { token.stop() }

        var didReplace = (trigger == .manual)

        // 결과를 한 번에 할당하지 않고, 배치 단위로 스트리밍
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
                // 슬라이더 연속 변경 등으로 "이전 스캔" 결과면 버림
                guard self.activeScanID == scanID else { return }

                if shouldReplace {
                    self.folderResults = batch
                } else {
                    self.folderResults.append(contentsOf: batch)
                }
            }

            didReplace = true
        }

        await MainActor.run {
            guard self.activeScanID == scanID else { return }

            self.isScanning = false
            self.isAutoUpdating = false
            self.lastScannedMinSizeMB = minSizeMB

            // 취소면 메시지만 갱신하고 종료
            if Task.isCancelled {
                self.scanMessage = "분석이 취소되었습니다."
                return
            }

            let results = self.folderResults
            let folderCount = results.filter { $0.isDirectory && $0.depth == 0 }.count
            let fileCount = results.filter { !$0.isDirectory }.count

            if results.isEmpty {
                self.scanMessage = "'\(root.lastPathComponent)' 폴더에 조건에 맞는 하위 항목이 없습니다."
            } else {
                self.scanMessage = "'\(root.lastPathComponent)' 폴더 분석이 완료되었습니다. (폴더 \(folderCount)개 / 파일 \(fileCount)개)"
            }
        }
    }
}

/// `scanStructuredItems` 결과를 한 번에 UI에 올리지 않고 배치 단위로 흘려보냅니다.
/// - Note: Table/State에 대량 배열을 한 번에 세팅하면 MainActor에서 UI가 잠깐 멈출 수 있어,
///         대용량 폴더 스캔에서는 배치 단위 업데이트가 체감이 좋습니다.
private static func scanStructuredItemsBatches(
    of root: URL,
    minSizeMB: Double,
    ignoredFolderURLs: Set<URL>,
    batchSize: Int
) -> AsyncStream<[FolderInfo]> {
    AsyncStream { continuation in
        // ✅ child Task(취소 전파됨)로 스캔 수행
        Task(priority: .userInitiated) {
            let results = Self.scanStructuredItems(of: root, minSizeMB: minSizeMB, ignoredFolderURLs: ignoredFolderURLs)

            var index = 0
            while index < results.count {
                if Task.isCancelled { break }

                let end = min(index + max(batchSize, 1), results.count)
                continuation.yield(Array(results[index..<end]))
                index = end

                // UI 업데이트 기회를 조금이라도 더 주기 위해 협조적 양보
                await Task.yield()
            }

            continuation.finish()
        }
    }
}

/// 선택한 폴더를 기준으로,

    /// - 루트 직계 하위 "폴더"(폴더 크기) + 루트 직계 "파일"
    /// - 그리고 각 폴더 내부(재귀)에서 조건(minSizeMB) 이상인 파일을
    ///   **해당 폴더 아래(depth=1)** 로 붙여서 반환합니다.
    ///
    /// ⚠️ macOS 14+ 의 Table(children:) 를 쓰지 않고도,
    /// Table에서 들여쓰기(depth)로 "하위 파일처럼" 보이게 하기 위한 구조입니다.
    private static func scanStructuredItems(of root: URL, minSizeMB: Double, ignoredFolderURLs: Set<URL>) -> [FolderInfo] {
        let fm = FileManager.default
        let rootStd = root.standardizedFileURL

        // 1) 루트 직계 하위 항목 읽기(폴더/파일 구분용)
        let dirKeys: [URLResourceKey] = [.isDirectoryKey]
        guard let items = try? fm.contentsOfDirectory(
            at: rootStd,
            includingPropertiesForKeys: dirKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // 2) 직계 하위 폴더(= 그룹의 상위 폴더) 크기 계산
        var topFolders: [FolderInfo] = []
        var topFolderURLSet: Set<URL> = []

        for raw in items {
            if Task.isCancelled { return [] }
            let url = raw.standardizedFileURL
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard isDir else { continue }
            if ignoredFolderURLs.contains(url) { continue }

            let size = Self.folderSizeBytes(at: url)
            let sizeMB = Double(size) / 1024.0 / 1024.0
            if sizeMB >= minSizeMB {
                topFolders.append(FolderInfo(url: url, sizeBytes: size, isDirectory: true, depth: 0, parentURL: nil))
                topFolderURLSet.insert(url)
            }
        }

        // 3) 재귀 파일 스캔(하위 파일을 "어느 상위 폴더 아래"로 붙일지 그룹핑)
        let fileKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]

        guard let enumerator = fm.enumerator(
            at: rootStd,
            includingPropertiesForKeys: fileKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return topFolders.sorted { $0.sizeBytes > $1.sizeBytes }
        }

        let rootComponents = rootStd.pathComponents

        var directFiles: [FolderInfo] = []                 // 루트 직계 파일
        var childFilesByTopFolder: [URL: [FolderInfo]] = [:]  // 상위 폴더URL -> (하위 파일들)

        for case let rawURL as URL in enumerator {
            if Task.isCancelled { break }
            let url = rawURL.standardizedFileURL

            // ignored 폴더면 하위도 전부 스킵
            if ignoredFolderURLs.contains(url) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard let values = try? url.resourceValues(forKeys: Set(fileKeys)) else { continue }
            guard values.isRegularFile == true else { continue }

            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            let sizeMB = Double(size) / 1024.0 / 1024.0
            guard sizeMB >= minSizeMB else { continue }

            // root 기준 상대 경로 components 계산
            let comps = url.pathComponents
            guard comps.count >= rootComponents.count else { continue }
            let rel = Array(comps.dropFirst(rootComponents.count))
            guard !rel.isEmpty else { continue }

            if rel.count == 1 {
                // 루트 직계 파일
                directFiles.append(FolderInfo(url: url, sizeBytes: size, isDirectory: false, depth: 0, parentURL: nil))
            } else {
                // root/TopFolder/.../file
                let topFolderName = rel[0]
                let topFolderURL = rootStd.appendingPathComponent(topFolderName, isDirectory: true).standardizedFileURL

                if topFolderURLSet.contains(topFolderURL) {
                    let child = FolderInfo(url: url, sizeBytes: size, isDirectory: false, depth: 1, parentURL: topFolderURL)
                    childFilesByTopFolder[topFolderURL, default: []].append(child)
                } else {
                    // 상위 폴더가(필터 때문에) 표시되지 않는 경우엔, 파일을 최상위로라도 노출
                    directFiles.append(FolderInfo(url: url, sizeBytes: size, isDirectory: false, depth: 0, parentURL: nil))
                }
            }
        }

        // 정렬
        topFolders.sort { $0.sizeBytes > $1.sizeBytes }
        directFiles.sort { $0.sizeBytes > $1.sizeBytes }

        // 최상위(폴더 + 루트직계 파일) 크기 기준 정렬
        let topLevel = (topFolders + directFiles).sorted { $0.sizeBytes > $1.sizeBytes }

        // 최종 출력: 폴더 바로 아래에 파일이 "하위 항목"처럼 나오도록 붙임
        var final: [FolderInfo] = []
        for entry in topLevel {
            final.append(entry)

            if entry.isDirectory {
                let children = (childFilesByTopFolder[entry.url] ?? []).sorted { $0.sizeBytes > $1.sizeBytes }
                final.append(contentsOf: children)
            }
        }

        return final
    }


    // MARK: - Ignore & Delete

    /// Finder에서 해당 폴더/앱을 바로 표시
    private func openInFinder(_ item: FolderInfo) {
        // 선택한 항목을 Finder에서 강조 표시
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// 행 우측 휴지통 아이콘: 실제 삭제 전에 확인 Alert를 띄우기 위한 트리거
    private func requestDelete(_ item: FolderInfo) {
        deleteTarget = item
        showingDeleteAlert = true
    }


    private func ignoreSelectedFolders() {
        let selected = folderResults.filter { tableSelection.contains($0.id) }
        guard !selected.isEmpty else { return }

        for item in selected {
            ignoredFolderURLs.insert(item.url.standardizedFileURL)

            if item.isDirectory {
                // 폴더를 무시하면, 표시된 하위 파일도 같이 제거
                folderResults.removeAll { $0.url == item.url || $0.parentURL == item.url }
            } else {
                folderResults.removeAll { $0.url == item.url }
            }
        }

        tableSelection.removeAll()
    }

    private func deleteSelectedFolders() {
        let selected = folderResults.filter { tableSelection.contains($0.id) }
        guard let first = selected.first else { return }
        deleteTarget = first
        showingDeleteAlert = true
    }

    private func confirmDelete() {
        guard let target = deleteTarget else { return }
        moveToTrash(target.url)

        ignoredFolderURLs.insert(target.url.standardizedFileURL)
        folderResults.removeAll { $0.url == target.url || $0.parentURL == target.url }
        tableSelection.removeAll()

        deleteTarget = nil
    }

    private func moveToTrash(_ url: URL) {
        let target = url.standardizedFileURL

        // ✅ 삭제 대상이 선택 폴더 하위라면 "선택 폴더"에 대해 Security-Scoped를 열어둔 상태에서 삭제
        let scopeURL: URL = {
            guard let root = selectedFolderURL?.standardizedFileURL else { return target }

            let rootPath = root.path.hasSuffix("/") ? root.path : (root.path + "/")
            let targetPath = target.path

            if targetPath == root.path || targetPath.hasPrefix(rootPath) {
                return root
            }
            return target
        }()

        let token = StorageSecurityScopedAccessToken(scopeURL)
        defer { token.stop() }

        do {
            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
        } catch {
            print("Trash failed:", error)
        }
    }
    
    // MARK: - Size Utilities

    private static func folderSizeBytes(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0

        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isRegularFile == true else { continue }

            if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                total += Int64(size)
            }
        }

        return total
    }
}

