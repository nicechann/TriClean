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
                Text("\(viewModel.usagePercent)% 사용중")  // 🔹 이제 도넛/아이콘과 동일
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
            // 여기서 refresh() 를 또 호출할지,
            // 이미 ContentView 쪽에서 주기적으로 refresh 중이면 생략해도 됩니다.
            viewModel.refresh()
        }
    }
}

#Preview {
    MenuMemoryView()
        .environmentObject(MemoryViewModel())
}

//import SwiftUI
//
//struct MenuMemoryView: View {
//    @StateObject private var vm = MemoryViewModel()
//
//    var body: some View {
//        VStack(alignment: .leading, spacing: 8) {
//            HStack {
//                Text("Memory")
//                    .font(.headline)
//                Spacer()
//                Text("\(vm.usagePercent)%")
//                    .font(.headline)
//            }
//
//            Text("Total: \(vm.totalMemoryText)")
//                .font(.caption)
//            Text("Used:  \(vm.usedMemoryText)")
//                .font(.caption)
//            Text("Free:  \(vm.freeMemoryText)")
//                .font(.caption)
//
//            Divider()
//
//            Button {
//                vm.performClean { _, _ in
//                    // 메뉴바 팝업에서는 굳이 토스트 안 띄우고 값만 새로고침
//                }
//            } label: {
//                Label("Clean Memory", systemImage: "sparkles")
//            }
//            .buttonStyle(.borderedProminent)
//            .controlSize(.small)
//        }
//        .padding(12)
//        .frame(width: 230)
//        .onAppear {
//            vm.refresh()
//        }
//    }
//}
