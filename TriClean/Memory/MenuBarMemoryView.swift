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
nonisolated struct MenuBarMemoryInfo: Sendable {
    let total: Double
    let used: Double
    let available: Double   // MB (Cached + Free)

    var usagePercent: Int {
        guard total > 0 else { return 0 }
        return Int((used / total * 100).rounded())
    }
}

@MainActor
final class MenuBarMemoryViewModel: ObservableObject {
    // ✅ 이중 발송 제거: @Published가 자동으로 objectWillChange를 처리함
    @Published var info = MenuBarMemoryInfo(total: 0, used: 0, available: 0)
    @Published var isRefreshing: Bool = false

    init() {
        refresh()
    }

    // ⚠️ 기존에는 `DispatchQueue.global(...).async` 안에서 `self.info`/`self.isRefreshing`
    //   (MainActor 프로퍼티)을 직접 변형했다. @Sendable 클로저가 비-Sendable한
    //   MainActor 클래스를 캡처하고 격리된 상태를 백그라운드에서 쓰는 구조라
    //   Swift 6에서는 에러다. 다른 ViewModel과 같은 구조화 동시성 패턴으로 교체한다.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task { [weak self] in
            let stats = await Task.detached(priority: .userInitiated) {
                MemoryReader.fetchStats()
            }.value

            guard let self else { return }

            let mb = 1024.0 * 1024.0
            let totalMB = Double(stats.totalBytes) / mb
            let usedMB  = Double(stats.usedBytes) / mb
            let availMB = Double(stats.availableBytes) / mb

            self.info = MenuBarMemoryInfo(
                total:     max(totalMB, 0),
                used:      max(usedMB, 0),
                available: max(availMB, 0)
            )
            self.isRefreshing = false
        }
    }

    // ✅ cleanMemory() 완전 제거 (Apple 심사 대응)
}

struct MenuBarMemoryView: View {
    @StateObject private var viewModel = MenuBarMemoryViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("menubar.memory.title".localized)
                .appFont(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("memory.total".localized(with: "\(Int(viewModel.info.total)) MB"))
                    Text("memory.used".localized(with: "\(Int(viewModel.info.used)) MB"))
                    Text("memory.available".localized(with: "\(Int(viewModel.info.available)) MB"))
                }
                .font(.system(.caption, design: .monospaced))

                Spacer()

                Text("\(viewModel.info.usagePercent)%")
                    .appFont(.title3)
                    .bold()
            }

            ProgressView(
                value: viewModel.info.used,
                total: max(viewModel.info.total, 1)
            )
            .scaleEffect(x: 1, y: 1.5, anchor: .center)

            // ✅ 면책 문구 추가 (Apple 심사 대응)
            Text("memory.menubar_disclaimer".localized)
                .appFont(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Divider()

            HStack {
                // ✅ Refresh 버튼만 유지 — "Clean" 버튼 완전 제거
                Button {
                    viewModel.refresh()
                } label: {
                    if viewModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("common.refresh".localized, systemImage: "arrow.clockwise")
                    }
                }
                .help("common.refresh".localized)
                .disabled(viewModel.isRefreshing)

                Spacer()

                Button {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: {
                    Text("menubar.open_triclean".localized)
                }
                .buttonStyle(.link)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

#Preview {
    MenuBarMemoryView()
}
