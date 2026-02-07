//
//  StorageView.swift
//  TriClean
//
//  Created by changyu Kang on 08/12/2025.
//

import SwiftUI
import AppKit
import StoreKit // ✅ 결제 기능을 위해 추가

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
            result.append(.init(name: "storage.legend.home".localized, bytes: homeUsed, color: Color(red: 0.98, green: 0.46, blue: 0.33)))
        }
        if appsUsed > 0 {
            result.append(.init(name: "storage.legend.apps".localized, bytes: appsUsed, color: Color(red: 0.99, green: 0.77, blue: 0.30)))
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
    
    // ✅ StoreManager, TrialManager 연결
    @EnvironmentObject private var storeManager: StoreManager
    @EnvironmentObject private var trialManager: TrialManager
    
    // ✅ Paywall 표시 여부
    @State private var showPaywall = false
    
    @State private var minFolderSizeMB: Double = 200
    @State private var selectedFolderURL: URL? = nil
    @State private var isScanning: Bool = false
    @State private var isAutoUpdating: Bool = false
    @State private var scanTask: Task<Void, Never>? = nil
    @State private var scanMessage: String = "storage.scan.default_msg".localized
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
    
    @State private var deleteTargets: [FolderInfo] = [] // 휴지통으로 이동할 대상(단일/복수)
    @State private var showingDeleteAlert = false        // 경고 다이얼로그 표시 여부
    
    @State private var activeScanID = UUID()
    @State private var lastScannedMinSizeMB: Double? = nil
    
    // 상위 폴더 정렬(발견순/이름/크기) — 스캔 중에는 항상 '발견순'으로 표시하고, 완료 후에만 1회 정렬 적용
    @State private var topFolderSort: TopFolderSort = .discovered
    
    // 스캔 결과의 '발견순' 스냅샷 (정렬 토글을 바꿔도 되돌릴 수 있도록 유지)
    @State private var discoveredResults: [FolderInfo] = []
    
    private var scanButtonBusyText: String {
        isAutoUpdating ? "Updating…" : "Scanning…"
    }
    
    private enum TopFolderSort: String, CaseIterable, Identifiable {
        case discovered
        case name
        case size
        
        var id: String { rawValue }
        
        var title: String {
            switch self {
            case .discovered: return "Default"
            case .name: return "Name"
            case .size: return "Size"
            }
        }
    }
    
    private enum ScanTrigger {
        case manual
        case auto
    }
    
    var body: some View {
        // ✅ 인셋 규칙을 고정(섹션 간 좌우 정렬 깨짐 방지)
        let outerPadding: CGFloat = 16
        let sectionInset: CGFloat = 12

        // ✅ 본문은 스크롤 가능, 배너는 safeAreaInset으로 하단에 고정
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                diskHeaderSection
                Divider()
                folderScanSection
                Divider()
                resultsTableSection
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
                TrialBottomBanner(
                    daysRemaining: trialManager.daysRemaining,
                    onBuyTap: { showPaywall = true }
                )
                .frame(maxWidth: .infinity)
                // ✅ 상단 섹션(디스크 카드 내부 12pt 인셋)과 동일한 좌우 정렬
                .padding(.horizontal, outerPadding + sectionInset)
                .padding(.vertical, 10)
                // 배너 영역은 불투명 배경으로 하단 프레임/스크롤 컨텐츠와 분리
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(allowDismiss: true)
                .environmentObject(storeManager)
        }
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
    
    private var folderScanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("storage.scan.header".localized)
                    .font(.title3.bold())
                
                Spacer()
                
                Button {
                    selectFolderAndScan()
                } label: {
                    // ✅ 버튼 폭/높이 고정: 상태(Select/Scanning/Updating)에 따라 크기가 변하지 않도록
                    ZStack {
                        // size anchor (invisible) — 가장 큰 케이스(텍스트 + 스피너) 기준으로 고정
                        Group {
                            Text("storage.scan.btn".localized)
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("storage.scan.updating".localized)
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
                            Text("storage.scan.btn".localized)
                                .lineLimit(1)
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(isScanning)
                
                if isScanning {
                    Button {
                        cancelActiveScan()
                    } label: {
                        Text("common.cancel".localized)
                            .lineLimit(1)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                }
                
            }
            
            // 안내 문구
            Text("storage.scan.tip".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 12) {
                Text("storage.scan.min_size".localized)
                    .font(.subheadline)
                    .frame(width: 120, alignment: .leading)
                
                Slider(value: $minFolderSizeMB, in: 10...2000, step: 10)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
                
                Text("\(Int(minFolderSizeMB)) MB+")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 90, alignment: .trailing)
                
                Spacer()
            }
            
            
            HStack(spacing: 12) {
                Text("storage.scan.sort".localized)
                    .font(.subheadline)
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $topFolderSort) {
                    ForEach(TopFolderSort.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .font(.subheadline)
                .frame(maxWidth: 270)
                
                Spacer()
            }
            .onChange(of: topFolderSort) { _ in
                // 스캔 중에는 재정렬하지 않고(흔들림/비용 방지), 완료 후에만 1회 적용
                guard !isScanning else { return }
                applyTopFolderSortFromDiscovered()
            }
            
            if isScanning && topFolderSort != .discovered {
                Text("storage.scan.sort.note".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Text(scanMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        // ✅ diskHeaderSection(내부 padding 12)과 같은 시작선으로 맞춤
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cancelActiveScan() {
        // ✅ 스캔 중단 (UI는 즉시 "취소 중…"으로 갱신)
        scanTask?.cancel()
        scanMessage = "storage.msg.canceling".localized
    }

    private var resultsTableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("storage.results.header".localized)
                    .font(.title3.bold())
                
                Spacer()
                
                Button(role: .destructive) {
                    deleteSelectedFolders()
                } label: {
                    Text("common.trash".localized)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(isScanning || tableSelection.isEmpty)
            }
            
            // ✅ TableColumnBuilder 안에 if를 두지 말고, Table 자체를 분기
            if folderResults.isEmpty {
                Table(folderResults, selection: $tableSelection) {
                    TableColumn("Item") { item in
                        let indent = CGFloat(item.depth) * 18
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
                }
            } else {
                Table(folderResults, selection: $tableSelection) {
                    TableColumn("Item") { item in
                        let indent = CGFloat(item.depth) * 18
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
                    
                    TableColumn("") { item in
                        Button {
                            openInFinder(item)
                        } label: {
                            Label("common.finder_app".localized, systemImage: "folder")
                        }
                        .labelStyle(.titleAndIcon)
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .help("common.finder".localized)
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
                        .help("common.trash".localized)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 44, ideal: 48, max: 52)
                }
            }
        }
        .frame(minHeight: 320)
        .alert("storage.alert.delete.title".localized, isPresented: $showingDeleteAlert) {
            Button("common.move_to_trash".localized, role: .destructive) { confirmDelete() }
            Button("common.cancel".localized, role: .cancel) { deleteTargets = [] }
        } message: {
            if deleteTargets.count == 1, let target = deleteTargets.first {
                let key = target.isDirectory ? "storage.alert.delete.msg_folder" : "storage.alert.delete.msg_file"
                Text(key.localized(with: target.name))
            } else {
                Text("storage.alert.delete.msg_multi".localized(with: deleteTargets.count))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sorting Policy (Top folders)
    
    @MainActor
    private func applyTopFolderSortFromDiscovered() {
        // 스캔 중에는 호출하지 않는 것을 전제로 합니다.
        switch topFolderSort {
        case .discovered:
            folderResults = discoveredResults
        case .name, .size:
            folderResults = Self.sortedTopFolderGroups(in: discoveredResults, by: topFolderSort)
        }
    }
    
    private static func sortedTopFolderGroups(in results: [FolderInfo], by mode: TopFolderSort) -> [FolderInfo] {
        guard mode != .discovered else { return results }
        
        var rootItems: [FolderInfo] = []
        rootItems.reserveCapacity(64)
        
        var topFolders: [FolderInfo] = []
        topFolders.reserveCapacity(64)
        
        var childrenByParent: [URL: [FolderInfo]] = [:]
        childrenByParent.reserveCapacity(64)
        
        // 1) 분류 + child map (원래 순서를 유지해 children 배열의 안정성을 보장)
        for item in results {
            if item.depth == 0, item.parentURL == nil, item.isDirectory {
                topFolders.append(item)
            } else if item.depth == 0, item.parentURL == nil, !item.isDirectory {
                // 루트 직계 파일(또는 기타 depth=0 파일)
                rootItems.append(item)
            } else if let parent = item.parentURL {
                childrenByParent[parent.standardizedFileURL, default: []].append(item)
            } else {
                rootItems.append(item)
            }
        }
        
        // 2) 상위 폴더 정렬 (폴더 row만 기준으로 그룹 단위 이동)
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
        
        // 3) 재구성: root 파일 → (상위 폴더 + 하위 파일)
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
        
        // 4) 안전망: 구조가 바뀌었거나 누락이 있으면 원래 순서대로 뒤에 추가
        if included.count != results.count {
            for item in results where !included.contains(item.id) {
                output.append(item)
            }
        }
        
        return output
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
    
    // MARK: - Folder Scan
    
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
            scanMessage = "storage.msg.manual".localized(with: url.lastPathComponent)
        case .auto:
            scanMessage = "storage.msg.auto".localized
        }
        
        // ✅ manual은 즉시 비우고 시작, auto는 첫 배치가 오기 전까지 기존 결과 유지(깜빡임 최소화)
        if trigger == .manual {
            folderResults = []
            discoveredResults = []
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
                        self.discoveredResults = batch
                    } else {
                        self.folderResults.append(contentsOf: batch)
                        self.discoveredResults.append(contentsOf: batch)
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
                    self.scanMessage = "storage.msg.canceled".localized
                    return
                }
                
                
                // ✅ auto 스캔에서 결과가 0개라 스트림이 한 번도 yield되지 않으면, 기존 결과가 남아있을 수 있어 비웁니다.
                if !didReplace {
                    self.folderResults = []
                    self.discoveredResults = []
                }
                
                // ✅ 스캔 완료 후에만 상위 폴더 정렬을 1회 적용(스캔 중 UI 흔들림 방지)
                self.applyTopFolderSortFromDiscovered()
                
                let results = self.folderResults
                let folderCount = results.filter { $0.isDirectory && $0.depth == 0 }.count
                let fileCount = results.filter { !$0.isDirectory }.count
                
                if results.isEmpty {
                    self.scanMessage = "storage.msg.no_items".localized(with: root.lastPathComponent)
                } else {
                    self.scanMessage = "storage.msg.completed".localized(with: root.lastPathComponent, folderCount, fileCount)
                }
            }
        }
    }
    
    /// `scanStructuredItems` 결과를 한 번에 UI에 올리지 않고 배치 단위로 흘려보냅니다.
    ///
    /// - v11: 전체 결과를 먼저 만든 뒤, 배치로 잘라 UI에 반영(최종 반영 시 멈춤 방지)
    /// - v12: **폴더 트리 탐색형 UX에 맞춰**, 스캔 진행 중에도 "폴더(상위) → 하위 파일" 단위로
    ///        순차적으로 yield 합니다. (대용량 폴더에서도 결과가 점진적으로 나타남)
    ///
    /// - Note:
    ///   - `batchSize`는 **UI 업데이트 빈도 제한(Throttle)** 용도입니다.
    ///   - 스캔 도중 정렬을 반복하면 Table diff 비용이 커질 수 있어,
    ///     여기서는 "폴더는 이름(안정성)" / "하위 파일은 size desc"로 정렬합니다.
    private static func scanStructuredItemsBatches(
        of root: URL,
        minSizeMB: Double,
        ignoredFolderURLs: Set<URL>,
        batchSize: Int
    ) -> AsyncStream<[FolderInfo]> {
        AsyncStream { continuation in
            let producer = Task.detached(priority: .utility) {
                let fm = FileManager.default
                let rootStd = root.standardizedFileURL
                
                // 1) 루트 직계 하위 항목
                let directKeys: [URLResourceKey] = [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey
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
                var rootFiles: [FolderInfo] = []
                rootFiles.reserveCapacity(64)
                
                for raw in directItems {
                    if Task.isCancelled { break }
                    
                    let url = raw.standardizedFileURL
                    if ignoredFolderURLs.contains(url) { continue }
                    
                    guard let values = try? url.resourceValues(forKeys: Set(directKeys)) else { continue }
                    
                    if values.isDirectory == true {
                        topFolders.append(url)
                        continue
                    }
                    
                    if values.isRegularFile == true {
                        let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                        let sizeMB = Double(size) / 1024.0 / 1024.0
                        if sizeMB >= minSizeMB {
                            rootFiles.append(FolderInfo(url: url, sizeBytes: size, isDirectory: false, depth: 0, parentURL: nil))
                        }
                    }
                }
                
                // 2) 루트 직계 파일(크기 기준) 먼저 표시
                rootFiles.sort { $0.sizeBytes > $1.sizeBytes }
                
                var idx = 0
                while idx < rootFiles.count {
                    if Task.isCancelled { break }
                    
                    let end = min(idx + max(batchSize, 1), rootFiles.count)
                    continuation.yield(Array(rootFiles[idx..<end]))
                    idx = end
                    await Task.yield()
                }
                
                // 3) 상위 폴더는 스캔 중에는 '발견순'(나열된 순서)을 유지합니다.
                //    정렬(Name/Size)은 스캔 완료 후 UI에서 1회 적용합니다.
                
                // 4) 각 상위 폴더를 "폴더(상위) → 하위 파일" 단위로 순차 yield
                //    - 폴더 크기(allocated size 합) 계산 + 하위 대용량 파일 수집(패키지 내부 파일은 목록에서 제외)
                let scanKeys: [URLResourceKey] = [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
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
                    
                    // 패키지(.app 등) 내부 파일은 목록에 노출하지 않기 위해 prefix 목록을 유지
                    // (size 계산은 포함)
                    var packagePrefixes: [String] = []
                    packagePrefixes.reserveCapacity(8)
                    
                    let minBytes = Int64(minSizeMB * 1024.0 * 1024.0)
                    
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
                        
                        guard let values = try? url.resourceValues(forKeys: Set(scanKeys)) else { continue }
                        
                        if values.isDirectory == true && values.isPackage == true {
                            let prefix = url.path.hasSuffix("/") ? url.path : (url.path + "/")
                            packagePrefixes.append(prefix)
                            continue
                        }
                        
                        guard values.isRegularFile == true else { continue }
                        
                        let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                        total += size
                        
                        // 하위 파일 리스트는 최소 크기 조건에 맞는 것만
                        guard size >= minBytes else { continue }
                        
                        // 패키지 내부 파일은 제외
                        let path = url.path
                        var isInsidePackage = false
                        for prefix in packagePrefixes {
                            if path.hasPrefix(prefix) {
                                isInsidePackage = true
                                break
                            }
                        }
                        if isInsidePackage { continue }
                        
                        children.append(FolderInfo(url: url, sizeBytes: size, isDirectory: false, depth: 1, parentURL: folder))
                    }
                    
                    if Task.isCancelled { break }
                    
                    // 폴더 자체도 minSizeMB 이상일 때만 표시
                    guard total >= minBytes else { continue }
                    
                    // 4-1) 폴더(상위) 먼저 yield
                    continuation.yield([
                        FolderInfo(url: folder, sizeBytes: total, isDirectory: true, depth: 0, parentURL: nil)
                    ])
                    await Task.yield()
                    
                    // 4-2) 하위 파일은 size desc로 정렬 후 배치 yield
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
    
    /// 선택한 폴더를 기준으로,
    
    /// - 루트 직계 하위 "폴더"(폴더 크기) + 루트 직계 "파일"
    /// - 그리고 각 폴더 내부(재귀)에서 조건(minSizeMB) 이상인 파일을
    ///   **해당 폴더 아래(depth=1)** 로 붙여서 반환합니다.
    ///
    /// ⚠️ macOS 14+ 의 Table(children:) 를 쓰지 않고도,
    /// Table에서 들여쓰기(depth)로 "하위 파일처럼" 보이게 하기 위한 구조입니다.
    ///
    /// - Note: v12에서는 스트리밍 방식으로 교체되어, 이 함수는 사용하지 않습니다.
    ///         (기존 구조 설명/참고용으로만 남겨둡니다)
    private static func scanStructuredItems(of root: URL, minSizeMB: Double, ignoredFolderURLs: Set<URL>) -> [FolderInfo] {
        // v12부터는 scanStructuredItemsBatches(스트리밍) 경로를 사용합니다.
        // 기존 코드 경로를 유지하고 싶다면 v11 버전을 참고하세요.
        return []
    }
    
    
    // MARK: - Ignore & Delete
    
    /// Finder에서 해당 폴더/앱을 바로 표시
    private func openInFinder(_ item: FolderInfo) {
        // 선택한 항목을 Finder에서 강조 표시
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
    
    /// 행 우측 휴지통 아이콘: 실제 삭제 전에 확인 Alert를 띄우기 위한 트리거
    private func requestDelete(_ item: FolderInfo) {
        deleteTargets = [item]
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
                discoveredResults.removeAll { $0.url == item.url || $0.parentURL == item.url }
            } else {
                folderResults.removeAll { $0.url == item.url }
                discoveredResults.removeAll { $0.url == item.url }
            }
        }
        
        tableSelection.removeAll()
    }
    
    private func deleteSelectedFolders() {
        let selected = folderResults.filter { tableSelection.contains($0.id) }
        guard !selected.isEmpty else { return }
        deleteTargets = selected
        showingDeleteAlert = true
    }
    
    private func confirmDelete() {
        let targets = deleteTargets
        guard !targets.isEmpty else { return }
        
        var succeededURLs = Set<URL>()
        
        for item in targets {
            if moveToTrash(item.url) {
                succeededURLs.insert(item.url.standardizedFileURL)
            }
        }
        
        // ✅ 휴지통 이동에 성공한 항목만 목록/무시 목록에서 제거
        guard !succeededURLs.isEmpty else {
            deleteTargets = []
            return
        }
        
        ignoredFolderURLs.formUnion(succeededURLs)
        
        folderResults.removeAll { info in
            let u = info.url.standardizedFileURL
            if succeededURLs.contains(u) { return true }
            if let p = info.parentURL?.standardizedFileURL, succeededURLs.contains(p) { return true }
            return false
        }
        
        discoveredResults.removeAll { info in
            let u = info.url.standardizedFileURL
            if succeededURLs.contains(u) { return true }
            if let p = info.parentURL?.standardizedFileURL, succeededURLs.contains(p) { return true }
            return false
        }
        
        let succeededIDs = Set(targets.filter { succeededURLs.contains($0.url.standardizedFileURL) }.map(\.id))
        tableSelection.subtract(succeededIDs)
        
        deleteTargets = []
    }
    
    private func moveToTrash(_ url: URL) -> Bool {
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
            return true
        } catch {
            print("Trash failed:", error)
            return false
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
