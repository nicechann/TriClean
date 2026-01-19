//
//  MenuMemoryView.swift
//  TriClean
//
//  Created by changyu Kang on 11/12/2025.
//

import SwiftUI

struct MenuMemoryView: View {
    // ✅ TriCleanApp 에서 넘겨준 공용 인스턴스를 그대로 사용
    @EnvironmentObject var viewModel: MemoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory")
                    .font(.headline)
                Spacer()
                
                // ✅ [수정] 단위(Percent/MB)에 따라 텍스트가 변경됨
                Text("\(viewModel.formattedCurrentUsage) 사용중")
                    .font(.headline)
            }

            Text("Total: \(viewModel.totalMemoryText)")
                .font(.caption)
            Text("Used:  \(viewModel.usedMemoryText)")
                .font(.caption)
            Text("Free:  \(viewModel.freeMemoryText)")
                .font(.caption)

            Divider()

            Button {
                viewModel.performClean { _, _ in }
            } label: {
                Label("Clean Memory", systemImage: "sparkles")
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
