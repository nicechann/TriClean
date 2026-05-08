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

final class MemoryViewModel: ObservableObject {

    @Published var stats: MemoryStats = .empty
    @Published var displayUnit: MemoryDisplayUnit = .percent

    // ✅ [삭제됨] cleanFillMode — 메모리 압박 모드 설정 제거

    // MARK: - Significant Memory Usage

    @Published var significantApps: [SignificantMemoryApp] = []
    @Published var isLoadingSignificantApps: Bool = false
    @Published var significantAppsUpdatedAt: Date? = nil

    // ✅ 중복 호출 방어용 타임스탬프 (메인 스레드에서만 접근)
    private var lastSignificantAppsRefresh: Date = .distantPast

    // ✅ [추가] 메뉴바 텍스트 자동 갱신용 Timer (5초 주기)
    //   - 사용자가 윈도우를 열지 않아도 메뉴바 숫자가 실시간으로 갱신됨
    //   - @StateObject로 보유되므로 앱 수명 동안 유지됨
    private var refreshTimer: Timer?

    init() {
        refresh()
        startAutoRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        // RunLoop.main에 스케줄되어 Timer 콜백이 항상 메인 스레드에서 실행됨
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
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
        DispatchQueue.global(qos: .userInitiated).async {
            let latest = MemoryReader.fetchStats()
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.stats = latest
                }
            }
        }
    }

    func refreshSignificantApps(limit: Int = 10) {
        // ✅ 메인 스레드에서만 호출되도록 가드 (lastSignificantAppsRefresh race 방지)
        dispatchPrecondition(condition: .onQueue(.main))

        // ✅ 5초 이내 중복 호출 방어
        guard Date().timeIntervalSince(lastSignificantAppsRefresh) > 5 else { return }
        lastSignificantAppsRefresh = Date()

        isLoadingSignificantApps = true

        DispatchQueue.global(qos: .utility).async {
            let apps = Self.fetchSignificantApps(limit: limit)
            DispatchQueue.main.async {
                self.significantApps = apps
                self.significantAppsUpdatedAt = Date()
                self.isLoadingSignificantApps = false
            }
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

    private static func fetchSignificantApps(limit: Int) -> [SignificantMemoryApp] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        var items: [SignificantMemoryApp] = []
        items.reserveCapacity(running.count)

        for app in running {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            guard let bytes = residentMemoryBytes(pid: pid) else { continue }
            items.append(SignificantMemoryApp(
                pid: pid,
                name: app.localizedName ?? "App",
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL,
                icon: app.icon,
                residentBytes: bytes
            ))
        }

        items.sort { $0.residentBytes > $1.residentBytes }
        if items.count > limit { items.removeSubrange(limit..<items.count) }
        return items
    }

    private static func residentMemoryBytes(pid: pid_t) -> Int64? {
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
        DispatchQueue.global(qos: .userInitiated).async {
            let after = MemoryReader.fetchStats()

            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.stats = after
                }
                self.lastSignificantAppsRefresh = .distantPast
                self.refreshSignificantApps()
                completion()
            }
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

enum MemoryReader {

    static func fetchStats() -> MemoryStats {
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
