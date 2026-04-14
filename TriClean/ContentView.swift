//
//  ContentView.swift
//  TriClean
//
//  ✅ Option A: Junk Cleaner를 Storage에 통합 — 사이드바에서 제거
//

import SwiftUI
import Combine

enum SidebarItem: Hashable {
    case storage
    case memory
    case apps
    case duplicates
    case settings
}

// 사이드바 상단에 표시할 상태 뱃지용 ViewModel
final class SidebarStatusViewModel: ObservableObject {
    @Published var memoryUsagePercent: Int = 0
    @Published var isRefreshing: Bool = false

    init() { refreshMemory() }

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

struct ContentView: View {

    @EnvironmentObject var memoryViewModel: MemoryViewModel
    @State private var selection: SidebarItem? = .storage

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("sidebar.section.system".localized) {
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
                }
                
                Section("sidebar.section.cleanup".localized) {
                    NavigationLink(value: SidebarItem.duplicates) {
                        Label("sidebar.duplicates".localized, systemImage: "doc.on.doc")
                    }
                }
                
                Section {
                    NavigationLink(value: SidebarItem.settings) {
                        Label("sidebar.settings".localized, systemImage: "gearshape")
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)

        } detail: {
            switch selection ?? .storage {
            case .storage:      StorageView()
            case .memory:       MemoryView()
            case .apps:         AppsView()
            case .duplicates:   DuplicateFinderView()
            case .settings:     SettingsView()
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

    // ✅ [삭제됨] CleanPreset / cleanPresetBinding — MemoryCleaner 제거에 따라 불필요

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
                            // ✅ [삭제됨] Cache Fill Mode

                            // 구매 상태 오버라이드
                            HStack(spacing: 12) {
                                Text("settings.debug.purchase_status".localized)
                                    .frame(width: 140, alignment: .leading)
                                Toggle("", isOn: $storeManager.debugPurchaseOverride)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                Text(storeManager.debugPurchaseOverride ? "settings.debug.purchase_on".localized : "settings.debug.purchase_off".localized)
                                    .font(.caption)
                                    .foregroundStyle(storeManager.debugPurchaseOverride ? Color.green : Color.secondary)
                            }

                            HStack(spacing: 12) {
                                Text("settings.debug.trial_days".localized)
                                    .frame(width: 140, alignment: .leading)
                                HStack(spacing: 6) {
                                    ForEach([0, 1, 3, 7], id: \.self) { days in
                                        Button("settings.debug.days_button".localized(with: days)) {
                                            trialManager.debugSetDaysRemaining(days)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .tint(trialManager.daysRemaining == days ? .accentColor : .secondary)
                                    }
                                    Button("settings.debug.actual_value".localized) {
                                        trialManager.debugResetTrialOverride()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                Text("settings.debug.current_days".localized(with: trialManager.daysRemaining))
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
