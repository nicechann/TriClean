//
//  ContentView.swift
//  TriClean
//
//  Created by changyu Kang on 08/12/2025.
//

import SwiftUI
import Combine

// 왼쪽 메뉴에 들어갈 섹션 정의
enum TriCleanSection: String, CaseIterable, Identifiable {
    case storage
    case memory
    case apps

    var id: Self { self }

    var title: String {
        switch self {
        case .storage: return "sidebar.storage".localized
        case .memory:  return "sidebar.memory".localized
        case .apps:    return "sidebar.apps".localized
        }
    }

    var subtitle: String {
        switch self {
        case .storage: return "sidebar.storage.subtitle".localized
        case .memory:  return "sidebar.memory.subtitle".localized
        case .apps:    return "sidebar.apps.subtitle".localized
        }
    }

    var systemImage: String {
        switch self {
        case .storage: return "externaldrive.fill"
        case .memory:  return "memorychip"
        case .apps:    return "app.fill"
        }
    }
}

// 사이드바 상단에 표시할 상태 뱃지용 ViewModel
final class SidebarStatusViewModel: ObservableObject {

    // ✅ [수정] 이중 objectWillChange 발송 제거
    // @Published가 자동으로 objectWillChange를 처리하므로
    // 수동 objectWillChange 선언 및 willSet 블록이 불필요합니다.
    @Published var memoryUsagePercent: Int = 0
    @Published var isRefreshing: Bool = false

    init() {
        refreshMemory()
    }

    func refreshMemory() {
        guard !isRefreshing else { return }
        isRefreshing = true

        DispatchQueue.global(qos: .userInitiated).async {
            let stats = MemoryReader.fetchStats()
            let used  = max(stats.appBytes + stats.wiredBytes + stats.compressedBytes, 0)
            let total = max(stats.totalBytes, 1)
            let percent = Int((Double(used) / Double(total)) * 100.0)

            DispatchQueue.main.async {
                self.memoryUsagePercent = max(0, min(100, percent))
                self.isRefreshing = false
            }
        }
    }
}

// 사이드바 상단 상태 뱃지 뷰
struct SidebarStatusView: View {
    @ObservedObject var viewModel: SidebarStatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TriClean")
                        .font(.headline)
                    Text(verbatim: "v\((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("sidebar.memory".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(viewModel.memoryUsagePercent)%")
                    .font(.caption)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }

            HStack {
                Text("sidebar.status.memory_usage".localized)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    viewModel.refreshMemory()
                } label: {
                    if viewModel.isRefreshing {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("sidebar.status.refresh_help".localized)
            }
        }
        .padding(.vertical, 6)
    }
}

// 사이드바 항목 식별용 enum
enum SidebarItem: Hashable {
    case storage
    case memory
    case apps
    case settings
}

struct ContentView: View {

    @EnvironmentObject var memoryViewModel: MemoryViewModel
    @State private var selection: SidebarItem? = .storage

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                NavigationLink(value: SidebarItem.storage) {
                    Label("sidebar.storage".localized, systemImage: "internaldrive")
                }
                NavigationLink(value: SidebarItem.memory) {
                    HStack {
                        Label("sidebar.memory".localized, systemImage: "memorychip")
                        Spacer()
                        Text(memoryViewModel.formattedCurrentUsage)
                            .font(.caption)
                    }
                }
                NavigationLink(value: SidebarItem.apps) {
                    Label("sidebar.apps".localized, systemImage: "app.dashed")
                }
                NavigationLink(value: SidebarItem.settings) {
                    Label("sidebar.settings".localized, systemImage: "gearshape")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)

        } detail: {
            switch selection ?? .storage {
            case .storage:  StorageView()
            case .memory:   MemoryView()
            case .apps:     AppsView()
            case .settings: SettingsView()
            }
        }
        .onAppear {
            if selection == nil { selection = .storage }
            memoryViewModel.refresh()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var memoryViewModel: MemoryViewModel
    @AppStorage("significantAppActivationMode") private var significantAppActivationMode: String = "single"
    #if DEBUG
    @EnvironmentObject var storeManager: StoreManager
    @EnvironmentObject var trialManager: TrialManager
    #endif

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }
    private var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
    }
    private var macOSVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    #if DEBUG
    private enum CleanPreset: String, CaseIterable, Identifiable {
        case random = "Random"
        case touch  = "Touch"
        case zero   = "0x00"
        case a5     = "0xA5"

        var id: String { rawValue }

        var mode: MemoryCleanFillMode {
            switch self {
            case .random: return .randomFill
            case .touch:  return .pageTouch
            case .zero:   return .zeroFill
            case .a5:     return .patternA5
            }
        }

        static func from(_ mode: MemoryCleanFillMode) -> CleanPreset {
            switch mode {
            case .randomFill:               return .random
            case .pageTouch:                return .touch
            case .memsetFill(let v):        return v == 0xA5 ? .a5 : .zero
            }
        }
    }

    private var cleanPresetBinding: Binding<CleanPreset> {
        Binding(
            get: { CleanPreset.from(memoryViewModel.cleanFillMode) },
            set: { memoryViewModel.cleanFillMode = $0.mode }
        )
    }
    #endif

    var body: some View {
        ScrollView {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {

                    // Display
                    GroupBox {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow(alignment: .top) {
                                Text("settings.menubar_unit".localized)
                                    .frame(width: 120, alignment: .leading)
                                VStack(alignment: .leading, spacing: 6) {
                                    Picker("", selection: $memoryViewModel.displayUnit) {
                                        ForEach(MemoryDisplayUnit.allCases) { unit in
                                            Text(unit.title).tag(unit)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 180, alignment: .leading)
                                    Text("settings.menubar_unit_desc".localized)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            GridRow(alignment: .top) {
                                Text("settings.app_activation".localized)
                                    .frame(width: 120, alignment: .leading)
                                VStack(alignment: .leading, spacing: 6) {
                                    Picker("", selection: $significantAppActivationMode) {
                                        Text("settings.app_activation.single".localized).tag("single")
                                        Text("settings.app_activation.all".localized).tag("all")
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .frame(width: 180, alignment: .leading)
                                    Text("settings.app_activation_desc".localized)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    } label: {
                        Text("settings.display".localized)
                    }

                    // About
                    GroupBox {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            GridRow {
                                Text("common.version".localized)
                                Text(appVersion).foregroundColor(.secondary)
                            }
                            GridRow {
                                Text("common.build".localized)
                                Text(buildNumber).foregroundColor(.secondary)
                            }
                            GridRow {
                                Text("common.macos".localized)
                                Text(macOSVersion)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    } label: {
                        Text("settings.about".localized)
                    }

                    // Help
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("settings.help.clean_desc".localized)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                            } label: {
                                Text("settings.help.clean_title".localized).font(.callout)
                            }

                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("settings.help.search_desc".localized)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                            } label: {
                                Text("settings.help.search_title".localized).font(.callout)
                            }
                        }
                        .padding(10)
                    } label: {
                        Text("settings.help".localized)
                    }

                    #if DEBUG
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {

                            // Cache Fill Mode
                            HStack(alignment: .center, spacing: 12) {
                                Text("settings.debug.clean_fill_mode".localized)
                                    .frame(width: 140, alignment: .leading)
                                Picker("", selection: cleanPresetBinding) {
                                    ForEach(CleanPreset.allCases) { preset in
                                        Text(preset.rawValue).tag(preset)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .controlSize(.small)
                                .frame(maxWidth: 420)
                            }
                            Text("settings.debug.clean_fill_desc".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Divider()

                            // 구매 상태 오버라이드
                            HStack(spacing: 12) {
                                Text("구매 상태 (isPurchased)")
                                    .frame(width: 140, alignment: .leading)
                                Toggle("", isOn: $storeManager.debugPurchaseOverride)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                Text(storeManager.debugPurchaseOverride ? "구매 완료" : "미구매")
                                    .font(.caption)
                                    .foregroundStyle(storeManager.debugPurchaseOverride ? Color.green : Color.secondary)
                            }

                            // 체험 기간 오버라이드
                            HStack(spacing: 12) {
                                Text("체험 기간 (daysRemaining)")
                                    .frame(width: 140, alignment: .leading)
                                HStack(spacing: 6) {
                                    ForEach([0, 1, 3, 7], id: \.self) { days in
                                        Button("\(days)일") {
                                            trialManager.debugSetDaysRemaining(days)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .tint(trialManager.daysRemaining == days ? .accentColor : .secondary)
                                    }
                                    Button("실제 값") {
                                        trialManager.debugResetTrialOverride()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                Text("현재 \(trialManager.daysRemaining)일")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                    } label: {
                        Text("settings.debug".localized)
                    }
                    #endif
                }
                .frame(minWidth: 560, idealWidth: 600, maxWidth: 640, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("sidebar.settings".localized)
    }
}

#Preview {
    ContentView()
        .environmentObject(MemoryViewModel())
        .environmentObject(StoreManager.shared)
        .environmentObject(TrialManager.shared)
}
