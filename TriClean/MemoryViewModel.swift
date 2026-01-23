//
//  MemoryViewModel.swift
//  TriClean
//
//  Created by changyu Kang on 09/12/2025.
//

import Foundation
import Combine
import Darwin       // Mach + sysconf (mach_host_self, host_statistics64, host_page_size, etc.)
import SwiftUI      // withAnimation

final class MemoryViewModel: ObservableObject {

    @Published var stats: MemoryStats = .empty
    @Published var displayUnit: MemoryDisplayUnit = .percent

    // MARK: - 공개 계산 값

    /// Activity Monitor 기준 '사용된 메모리' (App + Wired + Compressed)
    var realUsedBytes: Int64 {
        stats.appBytes + stats.wiredBytes + stats.compressedBytes
    }

    var usagePercent: Int {
        let total = max(stats.totalBytes, 1)
        return Int((Double(realUsedBytes) / Double(total) * 100).rounded())
    }

    var usageText: String { "\(usagePercent)%" }

    /// 현재 설정된 단위(%, MB)에 맞춰 변환된 문자열 (뷰에서 사용)
    var formattedCurrentUsage: String {
        switch displayUnit {
        case .percent:   return "\(usagePercent)%"
        case .megabytes: return formatBytes(realUsedBytes)
        }
    }

    var totalMemoryText: String { formatBytes(stats.totalBytes) }
    var usedMemoryText: String  { formatBytes(realUsedBytes) }
    var freeMemoryText: String  { formatBytes(stats.freeBytes) }
    var cachedMemoryText: String { formatBytes(stats.cachedBytes) }

    /// Available = Cached + Free (Activity Monitor의 “사용 가능” 개념)
    var availableBytes: Int64 { stats.cachedBytes + stats.freeBytes }
    var availableMemoryText: String { formatBytes(availableBytes) }

    // MARK: - API

    /// Native Mach VM 통계를 다시 읽어서 최신 메모리 정보로 갱신
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

    /// 가벼운 메모리 압박을 통해 OS 가 캐시를 정리하도록 유도
    func performClean(completion: @escaping (MemoryStats, MemoryStats) -> Void) {
        let before = stats
        DispatchQueue.global(qos: .userInitiated).async {
            MemoryCleaner.performLightClean(totalBytes: before.totalBytes)
            Thread.sleep(forTimeInterval: 0.5)
            let after = MemoryReader.fetchStats()

            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.stats = after
                }
                completion(before, after)
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

/// Native Mach VM 통계(host_statistics64)를 통해 메모리 구성 값을 읽어 MemoryStats 로 변환
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

        let ps = Int64(pageSize)

        // page counts
        let freePages       = Int64(vmStats.free_count)
        let activePages     = Int64(vmStats.active_count)
        let inactivePages   = Int64(vmStats.inactive_count)

        // speculative_count는 free_count에 포함되는 "free pages"의 부분집합이라
        // resident 계산에 더하면 double-count 위험이 있어 제외합니다.
        let wiredPages      = Int64(vmStats.wire_count)
        let compressedPages = Int64(vmStats.compressor_page_count)
        let fileBackedPages = Int64(vmStats.external_page_count) // File-backed pages
        let purgeablePages  = Int64(vmStats.purgeable_count)     // Purgeable pages

        // Activity Monitor 개념: Used = (Anonymous + Wired + Compressed)
        let totalResident  = activePages + inactivePages
        let anonymousPages = totalResident - fileBackedPages

        let appPages    = max(0, anonymousPages - purgeablePages)
        let cachedPages = fileBackedPages + purgeablePages

        return MemoryStats(
            appBytes:        appPages * ps,
            wiredBytes:      wiredPages * ps,
            compressedBytes: compressedPages * ps,
            cachedBytes:     cachedPages * ps,
            freeBytes:       freePages * ps
        )
    }
}

private enum MemoryCleaner {
    static func performLightClean(totalBytes: Int64) {
        guard totalBytes > 256 * 1024 * 1024 else { return }
        let rawTarget = totalBytes / 5
        let target = min(max(rawTarget, 64 * 1024 * 1024), 1024 * 1024 * 1024)
        let count = Int(target / 4)
        if count <= 0 { return }

        var buffer = [UInt32](repeating: 0, count: count)
        let step = 4096 / 4
        var i = 0
        while i < count {
            buffer[i] = UInt32.random(in: 0...100)
            i += step
        }
    }
}

