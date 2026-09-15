//
//  StorageView.swift
//  TriClean
//
//  Created by changyu Kang on 08/12/2025.
//

import SwiftUI
import AppKit
import StoreKit // ✅ 결제 기능을 위해 추가

// MARK: - 스캔 결과 모델 (폴더 + 파일)

// ⚠️ 아래 타입들은 전부 `nonisolated`다.
//   `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 때문에 명시하지 않으면 타입과
//   **합성 conformance(Equatable/Hashable)**, 계산 프로퍼티까지 MainActor로 추론된다.
//   이 값들은 `Task.detached` 스캔·해시 작업에서 생성·비교·정렬된다.
//   `Sendable` 선언만으로는 conformance 격리가 풀리지 않는다.
nonisolated struct FolderInfo: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let sizeBytes: Int64
    let isDirectory: Bool
    let fileIdentity: FileIdentitySnapshot?
    
    /// Table에서 "하위 항목처럼" 보이기 위한 들여쓰기 깊이
    /// - 0: 루트의 직계 결과(폴더/파일)
    /// - 1+: 폴더 하위로 표시되는 파일(현재는 1단계)
    let depth: Int
    
    /// depth > 0 인 경우, 어떤 상위 폴더 아래에 붙는지(표시/삭제 동기화용)
    let parentURL: URL?
    
    init(
        url: URL,
        sizeBytes: Int64,
        isDirectory: Bool,
        depth: Int = 0,
        parentURL: URL? = nil,
        fileIdentity: FileIdentitySnapshot? = nil
    ) {
        self.url = url
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.depth = depth
        self.parentURL = parentURL
        self.fileIdentity = fileIdentity ?? FileIdentitySnapshot.captureItem(url)
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
                    .appFont(.headline)
                Spacer()
                Text("storage.usage.format".localized(with: info.usedString, info.totalString))
                    .appFont(.caption)
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
                            .appFont(.caption2, monospacedDigit: true)
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
                        .appFont(.caption2)
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
            .appFont(.caption)
        }
    }
}

// MARK: - StorageView

struct StorageView: View {

    // 구매 상태 연결
    @EnvironmentObject private var storeManager: StoreManager

    // ✅ [공유 모델] 앱 레벨에서 주입된 동일 인스턴스를 사용 (SmartScan과 상태 공유)
    @EnvironmentObject private var junkViewModel: JunkScannerViewModel

    // ✅ 디스크 정보·폴더 크기 스캔 로직은 StorageViewModel로 이관했다.
    //   (다른 스캐너 화면과 동일한 패턴 — 취소 가능한 Task + 세대 번호 + 공용 북마크 저장소)
    @StateObject private var viewModel = StorageViewModel()

    // ✅ Paywall 표시 여부
    @State private var showPaywall = false

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
        // ✅ macOS 26: 스크롤된 안내 문구가 윈도우 제목과 겹치지 않도록 상단 가장자리 불투명 처리
        //    (Guideline 4 리뷰 스크린샷의 겹침 지점)
        .hardTopScrollEdge()
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
            viewModel.onAppear()

            if junkViewModel.libraryURL != nil && !junkViewModel.hasResults && !junkViewModel.isScanning {
                junkViewModel.scan()
            }
        }
        // ✅ 화면을 벗어나면 진행 중인 폴더 순회를 중단한다.
        //   (홈 폴더 전체 순회는 수 분이 걸릴 수 있어 방치하면 디스크 I/O가 계속된다.)
        .onDisappear {
            viewModel.onDisappear()
        }
    }

    // MARK: - UI Sections

    private var diskHeaderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("storage.header".localized)
                .appFont(.title2, weight: .bold)

            if let diskInfo = viewModel.diskInfo {
                DiskUsageSummaryView(
                    info: diskInfo,
                    homeBytes: viewModel.homeFolderBytes,
                    appsBytes: viewModel.appsFolderBytes,
                    isHomeSelected: viewModel.isHomeSelected,
                    isAppsSelected: viewModel.isAppsSelected,
                    isDetailScanning: viewModel.isDetailScanning
                )

                diskUsageScopeControls
            } else {
                Text("storage.loading".localized)
                    .appFont(.subheadline)
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
                Image(systemName: viewModel.isHomeSelected ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(viewModel.isHomeSelected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("storage.legend.home".localized)
                        .appFont(.caption, weight: .bold)
                    Text(viewModel.homeScopeURL?.path ?? "storage.scope.home_needed".localized)
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(viewModel.isHomeSelected ? "common.change".localized : "common.select".localized) {
                    viewModel.selectHomeFolderForDiskUsage()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                if viewModel.isHomeSelected {
                    Button("common.clear".localized) { viewModel.clearHomeFolderScope() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: viewModel.isAppsSelected ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(viewModel.isAppsSelected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("storage.legend.apps".localized)
                        .appFont(.caption, weight: .bold)
                    Text(viewModel.isAppsSelected ? viewModel.appsScopePathDescription : "storage.scope.apps_needed".localized)
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(viewModel.isAppsSelected ? "common.change".localized : "common.select".localized) {
                    viewModel.selectApplicationsFoldersForDiskUsage()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                if viewModel.isAppsSelected {
                    Button("common.clear".localized) { viewModel.clearApplicationsFoldersScope() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                }
            }

            Text("storage.scope.guide".localized)
                .appFont(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }
}
