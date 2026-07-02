//
//  MenuMemoryView.swift
//  TriClean
//
//  Created by changyu Kang on 11/12/2025.
//

import SwiftUI

struct MenuMemoryView: View {
    @EnvironmentObject var viewModel: MemoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("sidebar.memory".localized)
                    .font(.headline)
                Spacer()
                Text("memory.in_use".localized(with: viewModel.formattedCurrentUsage))
                    .font(.headline)
            }

            Text("memory.total".localized(with: viewModel.totalMemoryText))
                .font(.caption)
            Text("memory.used".localized(with: viewModel.usedMemoryText))
                .font(.caption)
            Text("memory.available".localized(with: viewModel.availableMemoryText))
                .font(.caption)

            Text("cpu.usage".localized(with: viewModel.cpuUsageText))
                .font(.caption)

            // ✅ 면책 문구 추가 — 수치가 추정값임을 명시 (Apple 심사 대응)
            Text("memory.menubar_disclaimer".localized)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Divider()

            // ✅ "Clean" 버튼 완전 제거 → Refresh(새로고침)만 유지
            Button {
                viewModel.refresh()
                viewModel.refreshSignificantApps()
            } label: {
                Label("common.refresh".localized, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 230)
        .onAppear {
            viewModel.refresh()
        }
    }
}

#Preview {
    MenuMemoryView()
        .environmentObject(MemoryViewModel())
}
