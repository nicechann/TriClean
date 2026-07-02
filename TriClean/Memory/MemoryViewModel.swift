//
//  MemoryViewModel.swift
//  TriClean
//
//  Created by changyu Kang on 09/12/2025.
//
//  ✅ [Apple 심사 대응 v2] MemoryCleaner 전체 삭제
//     - 메모리 압박(buffer alloc/touch) 코드 완전 제거
//     - performOptimize → 단순 refresh() 로 대체
//     - MemoryCleanFillMode enum 삭제
//     - 앱의 역할을 "모니터링 전용"으로 명확히 함
//
//  ✅ [수정 v4] Swift 6 동시성 경고 보완
//     - 백그라운드 Task에서는 Sendable 스냅샷만 수집하고 NSImage는 MainActor에서 생성.
//     - MemoryStats를 detached Task에서 안전하게 전달하도록 MemoryTypes에서 Sendable 채택.
//
//  ✅ [수정 v3] @MainActor 격리 적용
//     - 다른 ViewModel들과 일관되게 @MainActor로 격리.
//     - dispatchPrecondition 런타임 가드는 컴파일 타임 보장으로 대체되어 제거.
//     - Timer 콜백은 Task { @MainActor in ... } 로 안전하게 호출.
//     - performOptimize 시그니처는 호환성을 위해 동일하게 유지.

import Foundation
import Combine
import Darwin
import SwiftUI
import AppKit

// ✅ [삭제됨] MemoryCleanFillMode enum — 메모리 압박 관련 코드 전부 제거

/// 메모리 사용량 상위 앱(실행 중)을 표시하기 위한 모델
struct SignificantMemoryApp: Identifiable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    let icon: NSImage?
    let residentBytes: Int64

    var id: String { bundleIdentifier ?? "pid_\(pid)" }
}

private struct SignificantMemoryAppSnapshot: Sendable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    let residentBytes: Int64
}

@MainActor
final class MemoryViewModel: ObservableObject {

    @Published var stats: MemoryStats = .empty
    @Published var displayUnit: MemoryDisplayUnit = .percent

    // ✅ CPU 사용률(%). 누적 카운터 델타로 계산하므로 첫 샘플은 기준선만 잡고,
    //    두 번째 갱신(다음 5초)부터 값이 채워집니다. 그전에는 nil.
    @Published var cpuUsagePercent: Int? = nil

    // ✅ [삭제됨] cleanFillMode — 메모리 압박 모드 설정 제거

    // MARK: - Significant Memory Usage

    @Published var significantApps: [SignificantMemoryApp] = []
    @Published var isLoadingSignificantApps: Bool = false
    @Published var significantAppsUpdatedAt: Date? = nil

    // ✅ @MainActor 격리이므로 race 없이 안전하게 접근 가능
    private var lastSignificantAppsRefresh: Date = .distantPast

    // ✅ CPU 사용률 계산용 직전 tick 스냅샷 (@MainActor 격리로 race 없음)
    private var previousCPUTicks: CPUTicks? = nil

    // ✅ 메뉴바 텍스트 자동 갱신용 Timer (5초 주기)
    //   - 사용자가 윈도우를 열지 않아도 메뉴바 숫자가 실시간으로 갱신됨
    //   - @StateObject로 보유되므로 앱 수명 동안 유지됨
    private var refreshTimer: Timer?

    init() {
        refresh()
        startAutoRefresh()
    }

    deinit {
        // ✅ Timer는 메인 런루프에 스케줄되어 있으므로 nonisolated deinit에서도 안전하게 invalidate 가능.
        refreshTimer?.invalidate()
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        // RunLoop.main에 스케줄되어 Timer 콜백이 항상 메인 스레드에서 실행됨.
        // 콜백 클로저는 nonisolated 컨텍스트이므로 Task { @MainActor in ... } 로 격리 호핑.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    // MARK: - 공개 계산 값

    var realUsedBytes: Int64 {
        stats.appBytes + stats.wiredBytes + stats.compressedBytes
    }

    var usagePercent: Int {
        let total = max(stats.totalBytes, 1)
        return Int((Double(realUsedBytes) / Double(total) * 100).rounded())
    }

    var usageText: String { "\(usagePercent)%" }

    /// CPU 사용률 표시 문자열. 아직 표본이 없으면 "—".
    var cpuUsageText: String {
        guard let cpuUsagePercent else { return "—" }
        return "\(cpuUsagePercent)%"
    }

    var formattedCurrentUsage: String {
        switch displayUnit {
        case .percent:   return "\(usagePercent)%"
        case .megabytes: return formatBytes(realUsedBytes)
        }
    }

    var totalMemoryText:     String { formatBytes(stats.totalBytes) }
    var usedMemoryText:      String { formatBytes(realUsedBytes) }
    var freeMemoryText:      String { formatBytes(stats.freeBytes) }
    var cachedMemoryText:    String { formatBytes(stats.cachedBytes) }

    var availableBytes: Int64 { stats.cachedBytes + stats.freeBytes }
    var availableMemoryText: String { formatBytes(availableBytes) }

    // MARK: - API

    func refresh() {
        // 통계 수집은 짧지만 system call이므로 background에서 수행하고,
        // UI 반영만 MainActor에서 처리합니다.
        Task { @MainActor in
            // 메모리 통계와 CPU tick을 병렬로 수집
            async let statsTask = Self.fetchStatsInBackground(priority: .userInitiated)
            async let ticksTask = Self.fetchCPUTicksInBackground(priority: .userInitiated)
            let (latest, ticks) = await (statsTask, ticksTask)

            withAnimation(.easeInOut(duration: 0.25)) {
                self.stats = latest
            }
            self.updateCPUUsage(with: ticks)
        }
    }

    /// CPU tick 델타로 사용률을 계산해 반영합니다.
    /// 첫 호출은 기준선만 저장하고 값을 채우지 않습니다(누적 카운터라 두 표본의 차이가 필요).
    private func updateCPUUsage(with ticks: CPUTicks?) {
        guard let ticks else { return }
        defer { previousCPUTicks = ticks }

        guard let previous = previousCPUTicks else { return }

        // 누적 카운터의 wrap-around를 감안해 wrapping 뺄셈(&-) 사용
        let userDelta   = Double(ticks.user   &- previous.user)
        let systemDelta = Double(ticks.system &- previous.system)
        let niceDelta   = Double(ticks.nice   &- previous.nice)
        let idleDelta   = Double(ticks.idle   &- previous.idle)

        let usedDelta  = userDelta + systemDelta + niceDelta
        let totalDelta = usedDelta + idleDelta
        guard totalDelta > 0 else { return }

        let percent = Int((usedDelta / totalDelta * 100.0).rounded())
        withAnimation(.easeInOut(duration: 0.25)) {
            self.cpuUsagePercent = min(max(percent, 0), 100)
        }
    }

    nonisolated private static func fetchCPUTicksInBackground(priority: TaskPriority) async -> CPUTicks? {
        await Task.detached(priority: priority) {
            CPULoadReader.read()
        }.value
    }

    func refreshSignificantApps(limit: Int = 10) {
        // ✅ @MainActor 격리로 race 없음 — 별도 가드 불필요

        // ✅ 5초 이내 중복 호출 방어
        guard Date().timeIntervalSince(lastSignificantAppsRefresh) > 5 else { return }
        lastSignificantAppsRefresh = Date()

        isLoadingSignificantApps = true

        Task { @MainActor [weak self, limit] in
            let snapshots = await Task.detached(priority: .utility) {
                Self.fetchSignificantAppSnapshots(limit: limit)
            }.value

            guard let self else { return }
            self.significantApps = Self.makeSignificantApps(from: snapshots)
            self.significantAppsUpdatedAt = Date()
            self.isLoadingSignificantApps = false
        }
    }

    func activateSignificantApp(_ app: SignificantMemoryApp) {
        guard app.pid > 0 else { return }
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        let raw = UserDefaults.standard.string(forKey: "significantAppActivationMode") ?? "single"
        var options: NSApplication.ActivationOptions = [.activateIgnoringOtherApps]
        if raw == "all" { options.insert(NSApplication.ActivationOptions.activateAllWindows) }
        _ = running.activate(options: options)
    }

    nonisolated private static func fetchSignificantAppSnapshots(limit: Int) -> [SignificantMemoryAppSnapshot] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        var items: [SignificantMemoryAppSnapshot] = []
        items.reserveCapacity(running.count)

        for app in running {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            guard let bytes = residentMemoryBytes(pid: pid) else { continue }
            items.append(SignificantMemoryAppSnapshot(
                pid: pid,
                name: app.localizedName ?? "App",
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                residentBytes: bytes
            ))
        }

        items.sort { $0.residentBytes > $1.residentBytes }
        if items.count > limit { items.removeSubrange(limit..<items.count) }
        return items
    }

    private static func makeSignificantApps(from snapshots: [SignificantMemoryAppSnapshot]) -> [SignificantMemoryApp] {
        snapshots.map { snapshot in
            let runningIcon = NSRunningApplication(processIdentifier: snapshot.pid)?.icon
            let bundleIcon = snapshot.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }

            return SignificantMemoryApp(
                pid: snapshot.pid,
                name: snapshot.name,
                bundleIdentifier: snapshot.bundleIdentifier,
                bundleURL: snapshot.bundleURL,
                icon: runningIcon ?? bundleIcon,
                residentBytes: snapshot.residentBytes
            )
        }
    }

    nonisolated private static func fetchStatsInBackground(priority: TaskPriority) async -> MemoryStats {
        await Task.detached(priority: priority) {
            MemoryReader.fetchStats()
        }.value
    }

    nonisolated private static func residentMemoryBytes(pid: pid_t) -> Int64? {
        var info = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expectedSize)
        guard result == expectedSize else { return nil }
        return Int64(info.pti_resident_size)
    }

    // MARK: - ✅ [수정] performOptimize → 단순 refresh로 대체
    // 기존: 메모리 버퍼를 할당해 캐시 퍼지를 유도 → Apple 리젝 원인
    // 수정: 메모리 수치만 새로 읽어옴 (모니터링 전용)

    func performOptimize(completion: @escaping () -> Void) {
        // ✅ 단순히 메모리 통계를 새로 읽어오고 앱 목록을 갱신합니다.
        // 시스템 메모리 상태를 변경하지 않습니다.
        Task { @MainActor in
            let after = await Self.fetchStatsInBackground(priority: .userInitiated)

            withAnimation(.easeInOut(duration: 0.6)) {
                self.stats = after
            }
            self.lastSignificantAppsRefresh = .distantPast
            self.refreshSignificantApps()
            completion()
        }
    }

    // MARK: - 내부 포맷터

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - MemoryReader

nonisolated enum MemoryReader {

    nonisolated static func fetchStats() -> MemoryStats {
        // ✅ [수정] mach_host_self()는 task 전역 send right이므로
        //   mach_port_deallocate를 호출하면 안 됨 (반복 호출 시 포트 카운트 오류 누적).
        //   Apple 샘플 코드도 deallocate 하지 않음.
        let host = mach_host_self()

        var pageSize: vm_size_t = 0
        if host_page_size(host, &pageSize) != KERN_SUCCESS {
            pageSize = vm_size_t(sysconf(Int32(_SC_PAGESIZE)))
        }

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let kr: kern_return_t = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard kr == KERN_SUCCESS else { return .empty }

        let ps               = Int64(pageSize)
        let freePages        = Int64(vmStats.free_count)
        let activePages      = Int64(vmStats.active_count)
        let inactivePages    = Int64(vmStats.inactive_count)
        let speculativePages = Int64(vmStats.speculative_count)
        let wiredPages       = Int64(vmStats.wire_count)
        let compressedPages  = Int64(vmStats.compressor_page_count)
        let fileBackedPages  = Int64(vmStats.external_page_count)
        let purgeablePages   = Int64(vmStats.purgeable_count)

        _ = speculativePages

        let totalResident  = activePages + inactivePages
        let anonymousPages = totalResident - fileBackedPages
        let appPages       = max(0, anonymousPages - purgeablePages)
        let cachedPages    = fileBackedPages + purgeablePages

        return MemoryStats(
            appBytes:        appPages        * ps,
            wiredBytes:      wiredPages      * ps,
            compressedBytes: compressedPages * ps,
            cachedBytes:     cachedPages     * ps,
            freeBytes:       freePages       * ps
        )
    }
}

// ✅ [삭제됨] MemoryCleaner enum 전체 — 메모리 버퍼 할당/해제로 캐시 퍼지를 유도하는 코드
// Apple Guideline 1.1.6 위반: "부정확한 디바이스 데이터" 및 "오해를 유발하는 기능"
// 샌드박스 환경에서 메모리를 실제로 "최적화"할 수 없으며, 사용자에게 잘못된 기대를 줄 수 있음


// MARK: - CPULoadReader

/// host_statistics(HOST_CPU_LOAD_INFO)로 읽은 누적 CPU tick.
/// user/system/idle/nice는 부팅 이후 누적값이며, 두 시점의 차이로 사용률을 계산합니다.
nonisolated struct CPUTicks: Sendable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

nonisolated enum CPULoadReader {

    /// 전체 코어 집계 CPU tick을 읽어옵니다. 실패 시 nil.
    nonisolated static func read() -> CPUTicks? {
        // ✅ MemoryReader와 동일하게 mach_host_self()는 deallocate하지 않습니다.
        let host = mach_host_self()

        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(host, HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }

        guard kr == KERN_SUCCESS else { return nil }

        // cpu_ticks 인덱스: 0=USER, 1=SYSTEM, 2=IDLE, 3=NICE
        return CPUTicks(
            user:   info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle:   info.cpu_ticks.2,
            nice:   info.cpu_ticks.3
        )
    }
}
