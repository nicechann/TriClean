//
//  MenuBarMemoryView.swift
//  TriClean
//
//  Created by changyu Kang on 09/12/2025.
//

import SwiftUI
import Combine

// 메뉴바 전용, 간단 메모리 정보
struct MenuBarMemoryInfo {
    let total: Double   // MB
    let used: Double
    let free: Double

    var usagePercent: Int {
        guard total > 0 else { return 0 }
        return Int(used / total * 100)
    }
}

final class MenuBarMemoryViewModel: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    @Published var info = MenuBarMemoryInfo(total: 0, used: 0, free: 0) {
        willSet { objectWillChange.send() }
    }

    @Published var isCleaning: Bool = false {
        willSet { objectWillChange.send() }
    }

    init() {
        refresh()
    }

    func refresh() {
        // vm_stat을 이용해서 간단히 메모리 정보 가져오기
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")

            let pipe = Pipe()
            process.standardOutput = pipe

            do {
                try process.run()
            } catch {
                print("vm_stat 실행 실패: \(error)")
                return
            }

            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return
            }

            var pageSize: Double = 4096
            var freePages: Double = 0
            var activePages: Double = 0
            var inactivePages: Double = 0
            var wiredPages: Double = 0
            var compressedPages: Double = 0

            for line in output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("Mach Virtual Memory Statistics") {
                    if let range = trimmed.range(of: "page size of") {
                        let suffix = trimmed[range.upperBound...]
                        let comps = suffix.split(separator: " ")
                        if let first = comps.first, let ps = Double(first) {
                            pageSize = ps
                        }
                    }
                } else if trimmed.hasPrefix("Pages free") {
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
            let totalMB = totalPages * pageSize / 1024.0 / 1024.0
            let usedMB  = (activePages + inactivePages + wiredPages + compressedPages) * pageSize / 1024.0 / 1024.0
            let freeMB  = totalMB - usedMB

            DispatchQueue.main.async {
                self.info = MenuBarMemoryInfo(
                    total: totalMB,
                    used: usedMB,
                    free: max(freeMB, 0)
                )
            }
        }
    }

    func cleanMemory() {
        guard !isCleaning else { return }
        isCleaning = true

        DispatchQueue.global(qos: .userInitiated).async {
            // 실제로는 메모리 정리 로직을 넣을 부분
            // 여기서는 2초 정도 "작업 중" 표시만
            Thread.sleep(forTimeInterval: 2.0)

            DispatchQueue.main.async {
                self.refresh()
                self.isCleaning = false
            }
        }
    }

    private static func parsePages(from line: String) -> Double {
        let comps = line.components(separatedBy: CharacterSet.decimalDigits.inverted)
        for part in comps {
            if let v = Double(part) {
                return v
            }
        }
        return 0
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
                    Text("Free:  \(Int(viewModel.info.free)) MB")
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
                // 메인 앱 포커스
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
