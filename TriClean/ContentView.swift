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
        case .storage: return "Storage"
        case .memory:  return "Memory"
        case .apps:    return "Apps"
        }
    }

    var subtitle: String {
        switch self {
        case .storage: return "대용량 폴더 정리"
        case .memory:  return "메모리 모니터 & 정리"
        case .apps:    return "앱 관련 파일 정리"
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
                Text("Memory")
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
                Text("현재 사용 중인 메모리 비율입니다.")
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
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 12) {
                                Text("Menu Bar Unit")
                                    .frame(width: 120, alignment: .leading)

                                Picker("", selection: $memoryViewModel.displayUnit) {
                                    ForEach(MemoryDisplayUnit.allCases) { unit in
                                        Text(unit.title).tag(unit)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 180)
                            }

                            Text("메뉴바와 사이드바에 표시되는 메모리 단위를 선택합니다.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                    } label: {
                        Text("Display")
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
                        Text("About")
                    }

                    // Help (요약 + 자세히 보기)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {

                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("• 임시 버퍼를 할당/쓰기하여 메모리 압박을 만들고, OS가 캐시/압축 정책을 조정하도록 유도합니다.")
                                    Text("• 환경(여유 메모리/압축/스왑 상태)에 따라 변화 폭이 다를 수 있습니다.")
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                            } label: {
                                Text("Clean Memory: OS 메모리 정책 조정 유도")
                                    .font(.callout)
                            }

                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("• Spotlight 인덱싱이 꺼져 있거나 폴더가 제외되어 있으면 검색 결과가 비어 있을 수 있습니다.")
                                    Text("• 샌드박스 환경에서는 앱이 접근 가능한 경로만 대상으로 검색할 수 있습니다.")
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                            } label: {
                                Text("Apps 검색: Spotlight 인덱싱/제외 설정 영향")
                                    .font(.callout)
                            }
                        }
                        .padding(10)
                    } label: {
                        Text("Help")
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

//struct ContentView: View {
//
//    // TriCleanApp 에서 주입한 MemoryViewModel 환경 객체
//    @EnvironmentObject var memoryViewModel: MemoryViewModel
//
//    var body: some View {
//        NavigationSplitView {
//            // MARK: - 사이드바
//            List {
//                // STORAGE
//                NavigationLink {
//                    StorageView()
//                } label: {
//                    Label("Storage", systemImage: "internaldrive")
//                }
//
//                // MEMORY
//                NavigationLink {
//                    MemoryView()    // ✅ 여기서도 같은 환경 객체 사용
//                } label: {
//                    HStack {
//                        Label("Memory", systemImage: "memorychip")
//                        Spacer()
//                        // ✅ 도넛/상단 Usage 와 동일한 값
//                        Text("\(memoryViewModel.usagePercent)%")
//                            .font(.caption)
//                    }
//                }
//
//                // APPS
//                NavigationLink {
//                    AppsView()
//                } label: {
//                    Label("Apps", systemImage: "app.dashed")
//                }
//            }
//            .listStyle(.sidebar)
//
//        } detail: {
//            // 기본 Detail 화면 – 필요하면 StorageView() 등으로 변경 가능
//            MemoryView()
//        }
//        .onAppear {
//            // 앱 처음 뜰 때 실제 메모리 값 한 번 갱신
//            memoryViewModel.refresh()
//        }
//    }
//}
//
//#Preview {
//    ContentView()
//        .environmentObject(MemoryViewModel())
//}

//struct ContentView: View {
//    @State private var selection: TriCleanSection? = .storage
//    @StateObject private var statusViewModel = SidebarStatusViewModel()
//    // ✅ TriCleanApp 에서 내려준 MemoryViewModel
//    @EnvironmentObject var memoryViewModel: MemoryViewModel
//    //@StateObject private var memoryViewModel = MemoryViewModel()
//
//    var body: some View {
//        NavigationSplitView {
//            sidebar
//        } detail: {
//            detailView
//        }
//        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
//        .frame(minWidth: 900, minHeight: 600)
//    }
//
//    // MARK: - Sidebar
//
//    private var sidebar: some View {
//        List(selection: $selection) {
//            Section {
//                SidebarStatusView(viewModel: statusViewModel)
//            }
//
//            Section("기능") {
//                ForEach(TriCleanSection.allCases) { section in
//                    HStack(spacing: 8) {
//                        Image(systemName: section.systemImage)
//                            .frame(width: 20)
//                        VStack(alignment: .leading, spacing: 2) {
//                            Text(section.title)
//                                .font(.headline)
//                            Text(section.subtitle)
//                                .font(.caption)
//                                .foregroundColor(.secondary)
//                        }
//                    }
//                    .padding(.vertical, 4)
//                    .tag(section as TriCleanSection?)
//                }
//            }
//        }
//        .listStyle(.sidebar)
//    }
//
//    // MARK: - Detail
//
//    @ViewBuilder
//    private var detailView: some View {
//        switch selection {
//        case .storage, .none:
//            StorageView()
//                //.navigationTitle("Storage")
//        case .memory:
////            MemoryView(viewModel: memoryViewModel)
////            Text("\(memoryViewModel.usagePercent)%")
//
//            MemoryView()
//                //.navigationTitle("Memory")
//        case .apps:
//            AppsView()
//                //.navigationTitle("Apps")
//        }
//    }
//}
//
//#Preview {
//    ContentView()
//}

