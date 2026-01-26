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

    // ✅ 프로젝트 다른 ViewModel과 동일하게 명시적으로 구현
    let objectWillChange = ObservableObjectPublisher()

    @Published var memoryUsagePercent: Int = 0 {
        willSet { objectWillChange.send() }
    }

    @Published var isRefreshing: Bool = false {
        willSet { objectWillChange.send() }
    }

    init() {
        refreshMemory()
    }

    func refreshMemory() {
        guard !isRefreshing else { return }
        isRefreshing = true

        DispatchQueue.global(qos: .userInitiated).async {
            // Native Mach VM 통계 기반 (vm_stat 프로세스 호출 제거)
            let stats = MemoryReader.fetchStats()
            let used = max(stats.appBytes + stats.wiredBytes + stats.compressedBytes, 0)
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
                    Text("v1.0.0")
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
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(0.12))
                    )
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
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("메모리 사용률 새로고침")
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

    // TriCleanApp 에서 주입한 MemoryViewModel
    @EnvironmentObject var memoryViewModel: MemoryViewModel

    // 현재 선택된 사이드바 항목
    @State private var selection: SidebarItem? = .storage   // ✅ 기본값: storage

    var body: some View {
        NavigationSplitView {
            // MARK: - 사이드바
            List(selection: $selection) {
                // STORAGE
                NavigationLink(value: SidebarItem.storage) {
                    Label("Storage", systemImage: "internaldrive")
                }

                // MEMORY
                NavigationLink(value: SidebarItem.memory) {
                    HStack {
                        Label("Memory", systemImage: "memorychip")
                        Spacer()
                        Text(memoryViewModel.formattedCurrentUsage)
                            .font(.caption)
                    }
                }

                // APPS
                NavigationLink(value: SidebarItem.apps) {
                    Label("Apps", systemImage: "app.dashed")
                }

                // SETTINGS
                NavigationLink(value: SidebarItem.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320) // ✅ 추가

        } detail: {
            // MARK: - 오른쪽 상세 화면
            switch selection ?? .storage {   // ✅ 선택 없으면 storage 로
            case .storage:
                StorageView()

            case .memory:
                MemoryView()   // 같은 MemoryViewModel 을 EnvironmentObject 로 사용

            case .apps:
                AppsView()


            case .settings:
                SettingsView()
            }
        }
        .onAppear {
            // 앱 처음 뜰 때 Storage가 선택되도록 보정
            if selection == nil {
                selection = .storage
            }
            // 메모리 값 초기 로딩
            memoryViewModel.refresh()
        }
    }
}



// MARK: - Settings

/// 디버그/표시 옵션을 런타임에 바꾸기 위한 설정 화면
struct SettingsView: View {
    @EnvironmentObject var memoryViewModel: MemoryViewModel

    // Significant Memory Usage 영역에서 앱 아이콘 클릭 시 전환 방식
    // - single: 앱 전환(기본) / all: 앱의 모든 창을 앞으로
    @AppStorage("significantAppActivationMode") private var significantAppActivationMode: String = "single"

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
    // Debug 빌드에서만 노출되는 테스트 옵션 (출시본에서는 컴파일 제외)
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
            case .randomFill:
                return .random
            case .pageTouch:
                return .touch
            case .memsetFill(let value):
                return value == 0xA5 ? .a5 : .zero
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

                            // Menu Bar Unit
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

                            // App Activation
                            GridRow(alignment: .top) {
                                Text("settings.app_activation".localized)
                                    .frame(width: 120, alignment: .leading)

                                VStack(alignment: .leading, spacing: 6) {
                                    Picker("", selection: $significantAppActivationMode) {
                                        Text("Single").tag("single")
                                        Text("All").tag("all")
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
                                Text("Version")
                                Text(appVersion)
                                    .foregroundColor(.secondary)
                            }
                            GridRow {
                                Text("Build")
                                Text(buildNumber)
                                    .foregroundColor(.secondary)
                            }
                            GridRow {
                                Text("macOS")
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

                    // Help (요약 + 자세히 보기)
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
                                Text("settings.help.clean_title".localized)
                                    .font(.callout)
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
                                Text("settings.help.search_title".localized)
                                    .font(.callout)
                            }
                        }
                        .padding(10)
                    } label: {
                        Text("settings.help".localized)
                    }

                    #if DEBUG
                    // Debug (Debug 빌드에서만 노출)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 12) {
                                Text("Clean Fill Mode")
                                    .frame(width: 120, alignment: .leading)

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

                            Text("메모리 정리 시 버퍼를 채우는 방식(랜덤/페이지 터치/패턴)을 선택합니다. Release 빌드에서는 Touch로 고정됩니다.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                    } label: {
                        Text("Debug")
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
        .navigationTitle("Settings")
    }
}

#Preview {

    ContentView()
        .environmentObject(MemoryViewModel())
}
