//
//  MemoryViewModel.swift
//  TriClean
//
//  Created by changyu Kang on 09/12/2025.
//

import Foundation
import Combine
import Darwin
import SwiftUI
import AppKit

/// 메모리 압박(캐시/퍼지 유도)을 만들기 위해 "버퍼에 무엇을 쓰는지"를 선택하는 옵션입니다.
enum MemoryCleanFillMode: Equatable {
    case randomFill
    case pageTouch
    case memsetFill(value: UInt8)

    static let zeroFill:  MemoryCleanFillMode = .memsetFill(value: 0)
    static let patternA5: MemoryCleanFillMode = .memsetFill(value: 0xA5)
}

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

    @Published var cleanFillMode: MemoryCleanFillMode = {
        #if DEBUG
        return .randomFill
        #else
        return .pageTouch
        #endif
    }()

    // MARK: - Significant Memory Usage

    @Published var significantApps: [SignificantMemoryApp] = []
    @Published var isLoadingSignificantApps: Bool = false
    @Published var significantAppsUpdatedAt: Date? = nil

    // ✅ 중복 호출 방어용 타임스탬프
    private var lastSignificantAppsRefresh: Date = .distantPast

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

    // MARK: - ✅ performOptimize (기존 performClean 대체 — 이름/설명 완화)
    // 내부 동작은 동일하나, 외부 호출명과 UI 표현을 "Optimize"로 변경합니다.

    func performOptimize(completion: @escaping () -> Void) {
        let before = stats
        #if DEBUG
        let mode = cleanFillMode
        #else
        let mode: MemoryCleanFillMode = .pageTouch
        #endif

        DispatchQueue.global(qos: .userInitiated).async {
            let available = max(before.cachedBytes + before.freeBytes, 0)
            MemoryCleaner.performLightClean(
                totalBytes: before.totalBytes,
                availableBytes: available,
                fillMode: mode
            )
            Thread.sleep(forTimeInterval: 0.5)
            let after = MemoryReader.fetchStats()

            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.stats = after
                }
                // 최적화 이후 앱 목록 새로고침 (중복 방어 타임스탬프 우회)
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
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

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

// MARK: - MemoryCleaner

enum MemoryCleaner {

    @inline(never)
    private static func consume(_ value: UInt32) { _ = value }

    #if DEBUG
    private struct XSwUsage {
        var xsu_total: UInt64 = 0; var xsu_avail: UInt64 = 0
        var xsu_used: UInt64 = 0;  var xsu_pagesize: UInt32 = 0
        var xsu_encrypted: UInt32 = 0
    }
    private static func debugMB(_ bytes: Int64) -> String {
        String(format: "%.0fMB", Double(bytes) / 1048576.0)
    }
    private static func debugSwapUsageString() -> String {
        var x = XSwUsage(); var size = MemoryLayout<XSwUsage>.size
        guard sysctlbyname("vm.swapusage", &x, &size, nil, 0) == 0 else { return "swap: n/a" }
        func mb(_ v: UInt64) -> String { String(format: "%.0fMB", Double(v) / 1048576.0) }
        return "swap used \(mb(x.xsu_used))/\(mb(x.xsu_total)) (avail \(mb(x.xsu_avail)))"
    }
    #endif

    static func performLightClean(totalBytes: Int64, availableBytes: Int64, fillMode: MemoryCleanFillMode) {
        let MB: Int64 = 1024 * 1024
        let total     = max(totalBytes, 0)
        let available = max(availableBytes, 0)

        guard total     > 256 * MB else { return }
        guard available > 128 * MB else { return }

        let safety     = Int64(128 * MB)
        let maxAllowed = max(available - safety, 0)
        guard maxAllowed >= 16 * MB else { return }

        let rawTarget = available / 3
        let target    = min(min(max(rawTarget, 32 * MB), 256 * MB), maxAllowed)

        #if DEBUG
        print("[MemoryCleaner] total=\(debugMB(total)), available=\(debugMB(available)), target=\(debugMB(target)), mode=\(fillMode), \(debugSwapUsageString())")
        #endif

        let count = Int(target / 4)
        guard count > 0 else { return }

        var buffer = [UInt32](repeating: 0, count: count)
        buffer.withUnsafeMutableBytes { raw in
            guard let baseAddr = raw.baseAddress, raw.count > 0 else { return }
            switch fillMode {
            case .randomFill:
                arc4random_buf(baseAddr, raw.count)
            case .memsetFill(let value):
                _ = memset(baseAddr, Int32(value), raw.count)
            case .pageTouch:
                let pageSize = max(4096, Int(sysconf(Int32(_SC_PAGESIZE))))
                let bytes    = baseAddr.assumingMemoryBound(to: UInt8.self)
                var offset   = 0
                while offset < raw.count { bytes[offset] &+= 1; offset += pageSize }
            }
        }

        if !buffer.isEmpty { consume(buffer[buffer.count / 2]) }
    }
}
