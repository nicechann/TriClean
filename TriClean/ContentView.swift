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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")

            let pipe = Pipe()
            process.standardOutput = pipe

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                }
                return
            }

            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                }
                return
            }

            var freePages: Double = 0
            var activePages: Double = 0
            var inactivePages: Double = 0
            var wiredPages: Double = 0
            var compressedPages: Double = 0

            for line in output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("Pages free") {
                    freePages = Self.parsePages(from: trimmed)
                } else if trimmed.hasPrefix("Pages active") {
                    activePages = Self.parsePages(from: trimmed)
                } else if trimmed.hasPrefix("Pages inactive") {
                    inactivePages = Self.parsePages(from: trimmed)
                } else if trimmed.hasPrefix("Pages wired down") {
                    wiredPages = Self.parsePages(from: trimmed)
                } else if trimmed.hasPrefix("Pages occupied by compressor") {
                    compressedPages = Self.parsePages(from: trimmed)
                }
            }

            let totalPages = freePages + activePages + inactivePages + wiredPages + compressedPages
            let usedPages  = activePages + inactivePages + wiredPages + compressedPages

            let percent: Int
            if totalPages > 0 {
                // Double 비율 → Int %
                percent = Int((usedPages / totalPages) * 100.0)
            } else {
                percent = 0
            }

            DispatchQueue.main.async {
                self.memoryUsagePercent = max(0, min(100, percent))
                self.isRefreshing = false
            }
        }
    }

    private static func parsePages(from line: String) -> Double {
        let comps = line.components(separatedBy: CharacterSet.decimalDigits.inverted)
        for part in comps {
            if let value = Double(part) {
                return value
            }
        }
        return 0
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
