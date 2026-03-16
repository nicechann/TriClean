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
    @Environment(\.colorScheme) private var colorScheme

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
                significantAppsSection
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
            viewModel.refreshSignificantApps()
        }
    }

    private var availableBytes: Int64 {
        let s = viewModel.stats
        return max(s.totalBytes - (s.appBytes + s.wiredBytes + s.compressedBytes), Int64(0))
    }

    private func formatHeaderBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
    }

    // MARK: - 상단 요약

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("memory.in_use".localized(with: viewModel.usageText))
                    .font(.headline)

                Text("memory.total".localized(with: viewModel.totalMemoryText))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("memory.used".localized(with: viewModel.usedMemoryText))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("memory.available".localized(with: formatHeaderBytes(availableBytes)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                unitToggle
            }
        }
    }

    // ✅ headerSection에서만 쓰는 포맷터(뷰모델 formatBytes와 동일 포맷)
    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
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
                    Text("memory.clean_btn".localized) // 제목 겸 버튼
                        .font(.headline)
                    Text("memory.clean_desc".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    runClean()
                } label: {
                    Text("memory.clean_btn".localized)
                }
                .keyboardShortcut("m", modifiers: [.command])
            }
        }
    }

    // MARK: - 도넛 + 범례

    private var compositionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("memory.composition".localized)
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

                Text("memory.composition_note".localized)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    

// MARK: - Significant Memory Usage (Top Apps)

private var significantAppsSection: some View {
    GroupBox {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("memory.significant_usage".localized)
                    .font(.headline)

                Spacer()

                if viewModel.isLoadingSignificantApps {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        viewModel.refreshSignificantApps()
                    } label: {
                        Label("common.refresh".localized, systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if viewModel.significantApps.isEmpty {
                Text("memory.significant_empty".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.significantApps) { app in
                            Button {
                                viewModel.activateSignificantApp(app)
                            } label: {
                                VStack(spacing: 6) {
                                    Group {
                                        if let icon = app.icon {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .scaledToFit()
                                        } else {
                                            Image(systemName: "app")
                                                .resizable()
                                                .scaledToFit()
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .frame(width: 34, height: 34)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    // 메모리 사용량(읽기 쉬운 단위)
                                    Text(formatBytes(app.residentBytes))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .frame(width: 60)
                            }
                            .buttonStyle(.plain)
                            .help("memory.tooltip.app_click".localized(with: app.name, formatBytes(app.residentBytes)))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let updated = viewModel.significantAppsUpdatedAt {
                Text("common.updated".localized(with: updated.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private var legendSection: some View {
        let s = viewModel.stats

        // ✅ 도넛의 Available과 같은 톤으로 맞춤
        let availableColor: Color = (colorScheme == .dark)
            ? Color.white.opacity(0.38)
            : Color.black.opacity(0.10)

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
                color: availableColor,
                name: "Available",
                bytes: availableBytes
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
            let percent = (Double(bytes) / Double(total)) * 100.0
            if percent > 0, percent < 1 {
                return "<1%"
            }
            return String(format: "%.0f%%", percent)

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
        viewModel.performClean { _, _ in
            trayMessage = "memory.tray_message".localized
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

    // ✅ ViewModel의 단위를 감지하기 위해 EnvironmentObject 추가
    @EnvironmentObject var viewModel: MemoryViewModel
    @Environment(\.colorScheme) private var colorScheme

    let stats: MemoryStats

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let lineWidth = size * 0.18

            ZStack {
                // ✅ 배경 링은 “은은한 링”으로 (Available과 동일색 쓰지 않음)
                Circle()
                    .stroke(ringBackgroundColor, lineWidth: lineWidth)

                donutSegments(size: size, lineWidth: lineWidth)

                VStack(spacing: 4) {
                    Text(centerValueText)
                        .font(.system(size: size * 0.22, weight: .bold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)

                    Text(centerLabelText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(width: size * 0.7)
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private var ringBackgroundColor: Color {
        colorScheme == .dark
        ? Color.white.opacity(0.10)
        : Color.black.opacity(0.06)
    }

    private var availableColor: Color {
        // ✅ 사용자가 원한 “흰색 계열(다크)” 톤
        colorScheme == .dark
        ? Color.white.opacity(0.38)
        : Color.black.opacity(0.10)
    }

    // ✅ 중앙 라벨: "Usage" 대신 "In Use"(= Used 의미)로 명확화
    private var centerLabelText: String {
        "In Use"
    }

    // ✅ 단위에 따른 표시 텍스트 계산
    private var centerValueText: String {
        switch viewModel.displayUnit {
        case .percent:
            return "\(usagePercent)%"
        case .megabytes:
            // Activity Monitor 기준 실사용량 (App + Wired + Compressed)
            let realUsedBytes = stats.appBytes + stats.wiredBytes + stats.compressedBytes
            return formatBytes(realUsedBytes)
        }
    }
    
    // 내부 포맷터 (MB/GB 변환)
    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
    }

    private var usagePercent: Int {
        let total = max(stats.totalBytes, 1)
        
        // ViewModel과 동일하게 '캐시(Cached)'를 제외한 실사용량으로 계산
        // Activity Monitor: Used = App + Wired + Compressed
        let realUsedBytes = stats.appBytes + stats.wiredBytes + stats.compressedBytes
        
        return Int(
            (Double(realUsedBytes) / Double(total) * 100).rounded()
        )
    }

    private func donutSegments(size: CGFloat, lineWidth: CGFloat) -> some View {
        let total = max(stats.totalBytes, 1)

        let appRatio        = Double(stats.appBytes)        / Double(total)
        let wiredRatio      = Double(stats.wiredBytes)      / Double(total)
        let compressedRatio = Double(stats.compressedBytes) / Double(total)

        let usedRatio = max(0.0, min(appRatio + wiredRatio + compressedRatio, 1.0))
        let availableRatio = max(0.0, 1.0 - usedRatio) // Available = Cached + Free

        let startAngle = Angle(degrees: -90)

        return ZStack {
            Circle()
                .trim(from: 0, to: CGFloat(appRatio))
                .stroke(Color(red: 0.43, green: 0.84, blue: 0.41),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(startAngle)

            Circle()
                .trim(from: CGFloat(appRatio), to: CGFloat(appRatio + wiredRatio))
                .stroke(Color(red: 0.99, green: 0.71, blue: 0.31),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(startAngle)

            Circle()
                .trim(from: CGFloat(appRatio + wiredRatio), to: CGFloat(usedRatio))
                .stroke(Color(red: 0.69, green: 0.48, blue: 1.0),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(startAngle)

            // ✅ Available 색상 적용 (흰색 계열)
            Circle()
                .trim(from: CGFloat(usedRatio),
                      to: CGFloat(min(1.0, usedRatio + availableRatio)))
                .stroke(availableColor,
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
        .environmentObject(MemoryViewModel())
        .frame(width: 950, height: 600)
}


