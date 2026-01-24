//
//  MenuBarMemoryView.swift
//  TriClean
//
//  Created by changyu Kang on 09/12/2025.
//

import SwiftUI
import Combine
import AppKit

// 메뉴바 전용, 간단 메모리 정보
struct MenuBarMemoryInfo {
    let total: Double
    let used: Double
    let available: Double   // MB (Cached + Free)

    var usagePercent: Int {
        guard total > 0 else { return 0 }
        return Int((used / total * 100).rounded())
    }
}

final class MenuBarMemoryViewModel: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    @Published var info = MenuBarMemoryInfo(total: 0, used: 0, available: 0) {
        willSet { objectWillChange.send() }
    }

    @Published var isCleaning: Bool = false {
        willSet { objectWillChange.send() }
    }

    init() {
        refresh()
    }

    func refresh() {
        // ✅ 외부 프로세스(/usr/bin/vm_stat) 실행/파싱 제거
        // ✅ MemoryViewModel과 동일하게 Native Mach API 기반 MemoryReader.fetchStats() 사용
        DispatchQueue.global(qos: .userInitiated).async {
            let stats = MemoryReader.fetchStats()

            let mb = 1024.0 * 1024.0
            let totalMB = Double(stats.totalBytes) / mb

            // Activity Monitor 기준 Used = App + Wired + Compressed
            let usedBytes = stats.appBytes + stats.wiredBytes + stats.compressedBytes
            let usedMB = Double(usedBytes) / mb

            // Available = Cached + Free (표시 라벨은 기존 UI를 유지)
            let availableBytes = stats.cachedBytes + stats.freeBytes
            let availableMB = Double(availableBytes) / mb

            DispatchQueue.main.async {
                self.info = MenuBarMemoryInfo(
                    total: max(totalMB, 0),
                    used:  max(usedMB, 0),
                    available: max(availableMB, 0)
                )
            }
        }
    }

    func cleanMemory() {
        guard !isCleaning else { return }
        isCleaning = true

        DispatchQueue.global(qos: .userInitiated).async {
            // TODO: 실제 메모리 정리 로직 연결 시 여기에 구현
            Thread.sleep(forTimeInterval: 2.0)

            DispatchQueue.main.async {
                self.refresh()
                self.isCleaning = false
            }
        }
    }
}

struct MenuBarMemoryView: View {
    @StateObject private var viewModel = MenuBarMemoryViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TriClean – Memory")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total: \(Int(viewModel.info.total)) MB")
                    Text("Used:  \(Int(viewModel.info.used)) MB")
                    Text("Available:  \(Int(viewModel.info.available)) MB")
                }
                .font(.system(.caption, design: .monospaced))

                Spacer()

                Text("\(viewModel.info.usagePercent)%")
                    .font(.title3)
                    .bold()
            }

            ProgressView(
                value: viewModel.info.used,
                total: max(viewModel.info.total, 1)
            )
            .scaleEffect(x: 1, y: 1.5, anchor: .center)

            HStack {
                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")

                Spacer()

                Button {
                    viewModel.cleanMemory()
                } label: {
                    if viewModel.isCleaning {
                        ProgressView()
                    } else {
                        Text("Clean")
                    }
                }
                .disabled(viewModel.isCleaning)
            }

            Divider()

            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Text("Open TriClean")
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .frame(width: 280)
    }
}

#Preview {
    MenuBarMemoryView()
}

