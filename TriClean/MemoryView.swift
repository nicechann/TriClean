//
//  MemoryView.swift
//  TriClean
//
//  Created by changyu Kang on 08/12/2025.
//

import SwiftUI

struct MemoryView: View {

    // 앱 전체에서 공유하는 환경 객체 사용
    @EnvironmentObject var viewModel: MemoryViewModel
    //@StateObject private var viewModel = MemoryViewModel()
    //@ObservedObject var viewModel: MemoryViewModel   // ✅ 외부에서 주입

    // Clean Memory 후 우측 하단에 뜨는 트레이 상태
    @State private var showTray = false
    @State private var trayMessage = ""

    var body: some View {
        ZStack(alignment: .bottomTrailing) {

            // 메인 컨텐츠
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                cleanSection
                compositionSection
                Spacer()
            }
            .padding()

            // 우측 하단 트레이
            if showTray {
                TrayView(message: trayMessage)
                    .padding()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showTray)
        .onAppear {
            viewModel.refresh()
        }
    }

    // MARK: - 상단 요약

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Memory")
                .font(.largeTitle)
                .bold()

            HStack(spacing: 12) {
                Text("Usage: \(viewModel.usageText)")
                    .font(.headline)

                Spacer()

                Text("Total: \(viewModel.totalMemoryText)")
                    .font(.caption)
                Text("·  Used: \(viewModel.usedMemoryText)")
                    .font(.caption)
                Text("·  Free: \(viewModel.freeMemoryText)")
                    .font(.caption)
            }

            HStack {
                Spacer()

                // 단위 토글 (% / MB)
                unitToggle

//                Button {
//                    viewModel.refresh()
//                } label: {
//                    Label("Refresh", systemImage: "arrow.clockwise")
//                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - 단위 토글 (% / MB)

    private var unitToggle: some View {
        HStack(spacing: 0) {
            unitButton(.percent)
            unitButton(.megabytes)
        }
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.gray.opacity(0.4), lineWidth: 1)
        )
    }

    private func unitButton(_ unit: MemoryDisplayUnit) -> some View {
        let isSelected = (viewModel.displayUnit == unit)

        return Button {
            viewModel.displayUnit = unit
        } label: {
            Text(unit.title)
                .font(.caption)
                .frame(width: 40, height: 22)
                .background(
                    isSelected ? Color.accentColor.opacity(0.85) : Color.clear
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Clean Memory 카드

    private var cleanSection: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory Clean")
                        .font(.headline)
                    Text("사용 중인 메모리를 가볍게 정리해 여유 메모리를 확보합니다. 현재 작업 중인 앱은 종료하지 않습니다.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    runClean()
                } label: {
                    Text("Clean Memory")
                }
                .keyboardShortcut("m", modifiers: [.command])
            }
        }
    }

    // MARK: - 도넛 + 범례

    private var compositionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("메모리 구성")
                    .font(.headline)

                HStack(alignment: .center, spacing: 32) {
                    // 🔹 왼쪽에 여유 공간을 넣어서 도넛을 오른쪽으로 이동
                    Spacer(minLength: 100)

                    MemoryDonutView(stats: viewModel.stats)
                        .frame(width: 170, height: 170)

                    Spacer(minLength: 32)

                    legendSection
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 16)      // 제목과 도넛 사이
                .padding(.bottom, 30)    // 도넛과 하단 설명 사이

                Text("※ App / Wired / Compressed / Cached / Free 값은 macOS vm_stat 정보를 기반으로 계산한 실제 시스템 메모리 구성입니다.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private var legendSection: some View {
        let s = viewModel.stats
        return VStack(alignment: .leading, spacing: 8) {
            legendRow(
                color: Color(red: 0.43, green: 0.84, blue: 0.41),
                name: "App Memory",
                bytes: s.appBytes
            )
            legendRow(
                color: Color(red: 0.99, green: 0.71, blue: 0.31),
                name: "Wired Memory",
                bytes: s.wiredBytes
            )
            legendRow(
                color: Color(red: 0.69, green: 0.48, blue: 1.0),
                name: "Compressed",
                bytes: s.compressedBytes
            )
            legendRow(
                color: Color(red: 0.28, green: 0.62, blue: 1.0),
                name: "Cached Files",
                bytes: s.cachedBytes
            )
            legendRow(
                color: Color.gray.opacity(0.7),
                name: "Free",
                bytes: s.freeBytes
            )
        }
    }

    private func legendRow(color: Color, name: String, bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(name)
            Spacer()
            Text(valueText(for: bytes))
                .frame(width: 80, alignment: .trailing)
        }
        .font(.caption)
    }

    private func valueText(for bytes: Int64) -> String {
        let total = max(viewModel.stats.totalBytes, 1)

        switch viewModel.displayUnit {
        case .percent:
            let ratio = Double(bytes) / Double(total)
            return String(format: "%.0f%%", ratio * 100.0)
        case .megabytes:
            let mb = Double(bytes) / (1024.0 * 1024.0)
            if mb >= 1024 {
                return String(format: "%.1f GB", mb / 1024.0)
            } else {
                return String(format: "%.0f MB", mb)
            }
        }
    }

    // MARK: - Actions

    private func runClean() {
        viewModel.performClean { before, after in
            let totalBefore = max(before.totalBytes, 1)
            let totalAfter  = max(after.totalBytes, 1)

            let beforeUsage = Int(
                (Double(before.usedBytes) / Double(totalBefore) * 100).rounded()
            )
            let afterUsage = Int(
                (Double(after.usedBytes) / Double(totalAfter) * 100).rounded()
            )

            trayMessage = "정리 전 \(beforeUsage)% → 정리 후 \(afterUsage)% (실제 시스템 기준)"
            withAnimation {
                showTray = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    showTray = false
                }
            }
        }
    }
}

// MARK: - 도넛 차트 뷰

struct MemoryDonutView: View {

    let stats: MemoryStats

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let lineWidth = size * 0.18  // 도넛 두께

            ZStack {
                // 배경 링
                Circle()
                    .stroke(Color.gray.opacity(0.35), lineWidth: lineWidth)

                donutSegments(size: size, lineWidth: lineWidth)

                // 가운데 텍스트
                VStack(spacing: 4) {
                    Text("\(usagePercent)%")
                        .font(.system(size: size * 0.24, weight: .bold))
                    Text("Usage")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private var usagePercent: Int {
        let total = max(stats.totalBytes, 1)
        return Int(
            (Double(stats.usedBytes) / Double(total) * 100).rounded()
        )
    }

    private func donutSegments(size: CGFloat, lineWidth: CGFloat) -> some View {
        let total = max(stats.totalBytes, 1)

        let appRatio        = Double(stats.appBytes)        / Double(total)
        let wiredRatio      = Double(stats.wiredBytes)      / Double(total)
        let compressedRatio = Double(stats.compressedBytes) / Double(total)
        let cachedRatio     = Double(stats.cachedBytes)     / Double(total)
        //let freeRatio       = Double(stats.freeBytes)       / Double(total)

        let startAngle = Angle(degrees: -90)

        return ZStack {
            Circle()
                .trim(from: 0,
                      to: CGFloat(appRatio))
                .stroke(Color(red: 0.43, green: 0.84, blue: 0.41),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(startAngle)

            Circle()
                .trim(from: CGFloat(appRatio),
                      to: CGFloat(appRatio + wiredRatio))
                .stroke(Color(red: 0.99, green: 0.71, blue: 0.31),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(startAngle)

            Circle()
                .trim(from: CGFloat(appRatio + wiredRatio),
                      to: CGFloat(appRatio + wiredRatio + compressedRatio))
                .stroke(Color(red: 0.69, green: 0.48, blue: 1.0),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(startAngle)

            Circle()
                .trim(from: CGFloat(appRatio + wiredRatio + compressedRatio),
                      to: CGFloat(appRatio + wiredRatio + compressedRatio + cachedRatio))
                .stroke(Color(red: 0.28, green: 0.62, blue: 1.0),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(startAngle)

            Circle()
                .trim(from: CGFloat(appRatio + wiredRatio + compressedRatio + cachedRatio),
                      to: 1.0)
                .stroke(Color.gray.opacity(0.7),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(startAngle)
        }
    }
}

// MARK: - 트레이 뷰

private struct TrayView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .imageScale(.medium)
            Text(message)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(radius: 6)
    }
}

// MARK: - Preview

#Preview {
    MemoryView()
        .environmentObject(MemoryViewModel())   // ✅ 미리보기 전용
        .frame(width: 950, height: 600)
}

//#Preview {
//    MemoryView()
//    //MemoryView(viewModel: memoryViewModel)
//        .frame(width: 950, height: 600)
//}
