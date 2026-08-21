//
//  SmartScanView.swift
//  TriClean
//
//  Smart Scan dashboard: existing scan engines are reused as read-only summaries.
//  Destructive actions remain in each detail screen.
//

import SwiftUI
import Combine

@MainActor
final class SmartScanViewModel: ObservableObject {
    @Published var diskInfo: DiskInfo?
    @Published var lastScanDate: Date?
    @Published var statusMessage: String = "smartscan.status.ready".localized

    func refreshDiskInfo() {
        let volumeURL = FileManager.default.homeDirectoryForCurrentUser

        do {
            let values = try volumeURL.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])

            guard let total = values.volumeTotalCapacity else {
                diskInfo = nil
                statusMessage = "smartscan.status.disk_unavailable".localized
                return
            }

            let free: Int64 = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)

            let totalBytes = Int64(total)
            let freeBytes = max(Int64(0), min(free, totalBytes))
            let usedBytes = max(Int64(0), totalBytes - freeBytes)

            diskInfo = DiskInfo(
                name: values.volumeName ?? "Macintosh HD",
                totalBytes: totalBytes,
                freeBytes: freeBytes,
                usedBytes: usedBytes
            )
            lastScanDate = Date()
            statusMessage = "smartscan.status.updated".localized
        } catch {
            diskInfo = nil
            statusMessage = "smartscan.status.disk_unavailable".localized
        }
    }
}

struct SmartScanView: View {
    @EnvironmentObject private var memoryViewModel: MemoryViewModel

    @StateObject private var viewModel = SmartScanViewModel()
    // ✅ [공유 모델] 앱 레벨에서 주입된 동일 인스턴스를 사용 (각 상세 탭과 상태 공유)
    @EnvironmentObject private var junkViewModel: JunkScannerViewModel
    @EnvironmentObject private var duplicateViewModel: DuplicateScannerViewModel
    @EnvironmentObject private var appsViewModel: AppsViewModel

    let onNavigate: (SidebarItem) -> Void

    private var isScanning: Bool {
        junkViewModel.isScanning || duplicateViewModel.isScanning || appsViewModel.isLoadingInstalledApps
    }

    private var memoryUsagePercent: Int {
        let total = max(memoryViewModel.stats.totalBytes, 1)
        return Int((Double(memoryViewModel.realUsedBytes) / Double(total)) * 100.0)
    }

    private var memoryUsedString: String {
        ByteCountFormatter.string(fromByteCount: memoryViewModel.realUsedBytes, countStyle: .memory)
    }

    private var memoryTotalString: String {
        ByteCountFormatter.string(fromByteCount: memoryViewModel.stats.totalBytes, countStyle: .memory)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerSection
                overviewGrid
                actionSection
                detailCards
                safetyNote
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            memoryViewModel.refresh()
            viewModel.refreshDiskInfo()
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "speedometer")
                    .appIconFont(30, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 6) {
                Text("smartscan.title".localized)
                    .appFont(.largeTitle, weight: .bold)
                Text("smartscan.subtitle".localized)
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text(lastUpdatedText)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            Spacer()

            Button {
                runSmartScan()
            } label: {
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("smartscan.action.scanning".localized)
                    }
                } else {
                    Label("smartscan.action.scan".localized, systemImage: "magnifyingglass")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isScanning)
        }
    }

    private var lastUpdatedText: String {
        guard let date = viewModel.lastScanDate else { return "smartscan.last.never".localized }
        return "smartscan.last.updated".localized(with: date.formatted(date: .abbreviated, time: .shortened))
    }

    private var overviewGrid: some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 220), spacing: 12)
        ], alignment: .leading, spacing: 12) {
            overviewCard(
                title: "smartscan.storage.title".localized,
                value: viewModel.diskInfo?.freeString ?? "—",
                caption: viewModel.diskInfo.map { "smartscan.storage.caption".localized(with: $0.usedString, $0.totalString) } ?? "smartscan.storage.caption_unavailable".localized,
                systemImage: "internaldrive",
                progress: storageUsageRatio
            )

            overviewCard(
                title: "smartscan.memory.title".localized,
                value: "\(memoryUsagePercent)%",
                caption: "smartscan.memory.caption".localized(with: memoryUsedString, memoryTotalString),
                systemImage: "memorychip",
                progress: Double(memoryUsagePercent) / 100.0
            )

            overviewCard(
                title: "smartscan.cpu.title".localized,
                value: memoryViewModel.cpuUsageText,
                caption: "smartscan.cpu.caption".localized,
                systemImage: "cpu",
                progress: memoryViewModel.cpuUsagePercent.map { Double($0) / 100.0 }
            )

            overviewCard(
                title: "smartscan.junk.title".localized,
                value: junkValueText,
                caption: junkCaptionText,
                systemImage: "trash.circle",
                progress: junkReclaimableRatio,
                progressLabel: reclaimableProgressLabel(for: junkReclaimableRatio)
            )

            overviewCard(
                title: "smartscan.duplicates.title".localized,
                value: duplicateValueText,
                caption: duplicateCaptionText,
                systemImage: "doc.on.doc",
                progress: duplicateReclaimableRatio,
                progressLabel: reclaimableProgressLabel(for: duplicateReclaimableRatio)
            )
        }
    }

    private var storageUsageRatio: Double? {
        guard let diskInfo = viewModel.diskInfo else { return nil }
        return min(max(diskInfo.usedRatio, 0), 1)
    }

    /// 정리 가능 용량을 전체 디스크 용량 대비 비율로 표시합니다.
    /// 임의 스케일을 사용하지 않아 진행바와 실제 확보 가능 용량의 의미가 일치합니다.
    private func reclaimableRatio(bytes: Int64) -> Double? {
        guard let totalBytes = viewModel.diskInfo?.totalBytes,
              totalBytes > 0,
              bytes > 0 else { return nil }

        return min(max(Double(bytes) / Double(totalBytes), 0), 1)
    }

    private var junkReclaimableRatio: Double? {
        guard junkViewModel.hasResults else { return nil }
        return reclaimableRatio(bytes: junkViewModel.totalJunkBytes)
    }

    private var duplicateReclaimableRatio: Double? {
        guard !duplicateViewModel.groups.isEmpty else { return nil }
        return reclaimableRatio(bytes: duplicateViewModel.totalReclaimableBytes)
    }

    private func reclaimableProgressLabel(for ratio: Double?) -> String? {
        guard let ratio else { return nil }
        let percent = ratio.formatted(.percent.precision(.fractionLength(1)))
        return "smartscan.reclaimable.storage_ratio".localized(with: percent)
    }

    private var junkValueText: String {
        if junkViewModel.isScanning { return "smartscan.state.scanning".localized }
        if junkViewModel.libraryURL == nil { return "smartscan.state.permission".localized }
        if junkViewModel.accessDenied { return "smartscan.state.permission".localized }
        if junkViewModel.hasResults { return junkViewModel.totalJunkString }
        return "smartscan.state.ready".localized
    }

    private var junkCaptionText: String {
        if junkViewModel.libraryURL == nil { return "smartscan.junk.caption_permission".localized }
        if junkViewModel.accessDenied { return "smartscan.junk.caption_access".localized }
        if junkViewModel.isScanning { return junkViewModel.scanProgress.isEmpty ? "smartscan.junk.caption_scanning".localized : junkViewModel.scanProgress }
        if junkViewModel.hasResults { return "smartscan.junk.caption_found".localized(with: junkViewModel.results.count) }
        return "smartscan.junk.caption_ready".localized
    }

    private var duplicateValueText: String {
        if duplicateViewModel.isScanning { return "smartscan.state.scanning".localized }
        if duplicateViewModel.scanFolderURL == nil { return "smartscan.state.permission".localized }
        if duplicateViewModel.phase == .accessDenied { return "smartscan.state.permission".localized }
        if !duplicateViewModel.groups.isEmpty { return duplicateViewModel.totalReclaimableString }
        return "smartscan.state.ready".localized
    }

    private var duplicateCaptionText: String {
        if duplicateViewModel.scanFolderURL == nil { return "smartscan.duplicates.caption_permission".localized }
        if duplicateViewModel.phase == .accessDenied { return "duplicate.status.access_denied".localized }
        if duplicateViewModel.isScanning { return duplicateViewModel.statusMessage.isEmpty ? duplicateViewModel.phase.displayText : duplicateViewModel.statusMessage }
        if !duplicateViewModel.groups.isEmpty { return "smartscan.duplicates.caption_found".localized(with: duplicateViewModel.groups.count) }
        return "smartscan.duplicates.caption_ready".localized
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("smartscan.actions.title".localized)
                    .appFont(.title3, weight: .bold)
                Spacer()
                Text(viewModel.statusMessage)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                actionButton(
                    title: "smartscan.actions.storage".localized,
                    icon: "internaldrive",
                    target: .storage
                )
                actionButton(
                    title: "smartscan.actions.apps".localized,
                    icon: "app.dashed",
                    target: .apps
                )
                actionButton(
                    title: "smartscan.actions.duplicates".localized,
                    icon: "doc.on.doc",
                    target: .duplicates
                )
                actionButton(
                    title: "smartscan.actions.memory".localized,
                    icon: "memorychip",
                    target: .memory
                )
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var detailCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("smartscan.details.title".localized)
                .appFont(.title3, weight: .bold)

            VStack(spacing: 10) {
                detailRow(
                    title: "smartscan.details.storage.title".localized,
                    message: viewModel.diskInfo.map { "smartscan.details.storage.message".localized(with: $0.name, $0.freeString) } ?? "smartscan.storage.caption_unavailable".localized,
                    icon: "internaldrive",
                    status: "smartscan.status.checked".localized,
                    buttonTitle: "smartscan.details.open".localized,
                    target: .storage
                )

                detailRow(
                    title: "smartscan.details.junk.title".localized,
                    message: junkCaptionText,
                    icon: "trash.circle",
                    status: junkViewModel.libraryURL == nil ? "smartscan.status.permission_needed".localized : "smartscan.status.available".localized,
                    buttonTitle: "smartscan.details.open".localized,
                    target: .storage
                )

                detailRow(
                    title: "smartscan.details.apps.title".localized,
                    message: appsStatusText,
                    icon: "app.dashed",
                    status: appsViewModel.applicationsFolderURL == nil ? "smartscan.status.permission_needed".localized : "smartscan.status.available".localized,
                    buttonTitle: "smartscan.details.open".localized,
                    target: .apps
                )

                detailRow(
                    title: "smartscan.details.duplicates.title".localized,
                    message: duplicateCaptionText,
                    icon: "doc.on.doc",
                    status: duplicateViewModel.scanFolderURL == nil ? "smartscan.status.permission_needed".localized : "smartscan.status.available".localized,
                    buttonTitle: "smartscan.details.open".localized,
                    target: .duplicates
                )
            }
        }
    }

    private var appsStatusText: String {
        if appsViewModel.applicationsFolderURL == nil { return "smartscan.apps.caption_permission".localized }
        if appsViewModel.isLoadingInstalledApps { return "smartscan.apps.caption_scanning".localized }
        if appsViewModel.totalAppsCount > 0 {
            return "smartscan.apps.caption_found".localized(with: appsViewModel.totalAppsCount, appsViewModel.removableAppsCount)
        }
        return "smartscan.apps.caption_ready".localized
    }

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .appFont(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("smartscan.safety.title".localized)
                    .appFont(.headline)
                Text("smartscan.safety.body".localized)
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.green.opacity(0.08)))
    }

    private func overviewCard(
        title: String,
        value: String,
        caption: String,
        systemImage: String,
        progress: Double?,
        progressLabel: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: systemImage)
                    .appFont(.title3)
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if let progress {
                    Text(progressLabel ?? "\(Int(progress * 100))%")
                        .appFont(.caption, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                }
            }

            Text(value)
                .appFont(.title2, weight: .bold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(title)
                .appFont(.headline)

            Text(caption)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func actionButton(title: String, icon: String, target: SidebarItem) -> some View {
        Button {
            onNavigate(target)
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func detailRow(
        title: String,
        message: String,
        icon: String,
        status: String,
        buttonTitle: String,
        target: SidebarItem
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .appFont(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .appFont(.headline)
                    Text(status)
                        .appFont(.caption2, weight: .bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                }
                Text(message)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(buttonTitle) {
                onNavigate(target)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func runSmartScan() {
        memoryViewModel.refresh()
        viewModel.refreshDiskInfo()

        if junkViewModel.libraryURL != nil, !junkViewModel.isScanning {
            junkViewModel.scan()
        }

        if duplicateViewModel.scanFolderURL != nil, !duplicateViewModel.isScanning {
            duplicateViewModel.scan()
        }

        if appsViewModel.applicationsFolderURL != nil, !appsViewModel.isLoadingInstalledApps {
            appsViewModel.loadInstalledApps()
        }
    }
}
