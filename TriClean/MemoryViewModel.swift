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
import AppKit

/// 메모리 압박(캐시/퍼지 유도)을 만들기 위해 "버퍼에 무엇을 쓰는지"를 선택하는 옵션입니다.
///
/// - `randomFill`: `arc4random_buf`로 전체를 랜덤 바이트로 채움(가장 강한 write 압박)
/// - `pageTouch`: 각 메모리 페이지의 1바이트만 터치(최소 write로 페이지 커밋 유도)
/// - `memsetFill(value:)`: `memset`으로 특정 패턴 바이트로 전체를 채움
enum MemoryCleanFillMode: Equatable {
    case randomFill
    case pageTouch
    case memsetFill(value: UInt8)

    /// 흔히 쓰는 패턴(0) 채우기
    static let zeroFill: MemoryCleanFillMode = .memsetFill(value: 0)

    /// 디버그용 패턴(0xA5) 채우기
    static let patternA5: MemoryCleanFillMode = .memsetFill(value: 0xA5)
}



/// 메모리 사용량 상위 앱(실행 중)을 표시하기 위한 모델입니다.
struct SignificantMemoryApp: Identifiable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    let icon: NSImage?
    /// Resident memory(bytes). (Activity Monitor의 'Memory'와 완전히 동일하진 않을 수 있음)
    let residentBytes: Int64

    var id: String {
        // bundle id가 있으면 안정적 key로 사용, 없으면 pid 기반
        bundleIdentifier ?? "pid_\(pid)"
    }
}

final class MemoryViewModel: ObservableObject {

    @Published var stats: MemoryStats = .empty
    @Published var displayUnit: MemoryDisplayUnit = .percent

    /// 메모리 정리(압박) 시 버퍼 채우기 방식 선택
    /// - Debug 빌드: Settings > Debug 에서 변경 가능
    /// - Release 빌드: 안정성과 배터리/발열을 위해 `.pageTouch` 로 고정
    @Published var cleanFillMode: MemoryCleanFillMode = {
    #if DEBUG
        return .randomFill
    #else
        return .pageTouch
    #endif
    }()

    

// MARK: - Significant Memory Usage (Top Apps)

/// 메모리를 많이 사용 중인(상위) 실행 앱 목록입니다.
/// - `NSWorkspace.shared.runningApplications`로 앱 목록을 얻고,
/// - `proc_pidinfo(…, PROC_PIDTASKINFO, …)`로 각 PID의 resident memory를 조회합니다.
@Published var significantApps: [SignificantMemoryApp] = []
@Published var isLoadingSignificantApps: Bool = false
@Published var significantAppsUpdatedAt: Date? = nil

// MARK: - 공개 계산 값

    /// Activity Monitor 기준 '사용된 메모리' (App + Wired + Compressed)
    var realUsedBytes: Int64 {
        stats.appBytes + stats.wiredBytes + stats.compressedBytes
    }

    var usagePercent: Int {
        let total = max(stats.totalBytes, 1)
        return Int(
            (Double(realUsedBytes) / Double(total) * 100).rounded()
        )
    }

    var usageText: String {
        "\(usagePercent)%"
    }
    
    /// ✅ 현재 설정된 단위(%, MB)에 맞춰 변환된 문자열 (뷰에서 사용)
    var formattedCurrentUsage: String {
        switch displayUnit {
        case .percent:
            return "\(usagePercent)%"
        case .megabytes:
            return formatBytes(realUsedBytes)
        }
    }

    var totalMemoryText: String {
        formatBytes(stats.totalBytes)
    }

    var usedMemoryText: String {
        formatBytes(realUsedBytes)
    }

    var freeMemoryText: String {
        formatBytes(stats.freeBytes)
    }
    
    var cachedMemoryText: String {
        formatBytes(stats.cachedBytes)
    }

    // ✅ Available = Cached + Free (Activity Monitor의 “사용 가능” 개념에 맞춤)
    var availableBytes: Int64 {
        stats.cachedBytes + stats.freeBytes
    }

    var availableMemoryText: String {
        formatBytes(availableBytes)
    }

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


/// 실행 중인 앱 중 메모리를 많이 사용하는(상위) 앱 목록을 갱신합니다.
/// - UI 프리징을 막기 위해 백그라운드에서 계산한 뒤 MainActor에서 Published 값을 갱신합니다.
func refreshSignificantApps(limit: Int = 10) {
    // 너무 잦은 갱신은 피로감/CPU 사용 증가로 이어질 수 있어, 호출 측에서 주기를 제어하는 것을 권장합니다.
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

    /// Significant Apps 영역에서 앱 아이콘을 클릭했을 때, 해당 앱을 전면으로 활성화합니다.
    /// - Note: MAS/Sandbox 환경을 고려해 외부 프로세스 실행 없이 AppKit API만 사용합니다.
    func activateSignificantApp(_ app: SignificantMemoryApp) {
        guard app.pid > 0 else { return }
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        // Settings에서 선택한 정책에 따라 활성화 강도를 조절합니다.
        // - single: 앱만 활성화(기본에 가까움) + 필요 시 전면 전환
        // - all: 앱의 모든 윈도우를 전면으로 올림
        let raw = UserDefaults.standard.string(forKey: "significantAppActivationMode") ?? "single"

        // NSRunningApplication.activate(options:) 가 요구하는 타입은
        // NSRunningApplication.ActivationOptions 가 아니라 NSApplication.ActivationOptions 입니다.
        // (옵션 enum 은 NSApplication 에 정의됨)
        var options: NSApplication.ActivationOptions = [.activateIgnoringOtherApps]
        if raw == "all" {
            // 타입 추론 이슈를 피하기 위해 fully-qualified 로 넣습니다.
            options.insert(NSApplication.ActivationOptions.activateAllWindows)
        }

        _ = running.activate(options: options)
    }

private static func fetchSignificantApps(limit: Int) -> [SignificantMemoryApp] {
    // 사용자에게 의미 있는 앱 위주로: 일반 앱(activationPolicy == .regular)만 우선 표시
    let running = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }

    var items: [SignificantMemoryApp] = []
    items.reserveCapacity(running.count)

    for app in running {
        let pid = app.processIdentifier
        guard pid > 0 else { continue }
        guard let bytes = residentMemoryBytes(pid: pid) else { continue }

        let item = SignificantMemoryApp(
            pid: pid,
            name: app.localizedName ?? "App",
            bundleIdentifier: app.bundleIdentifier,
            bundleURL: app.bundleURL,
            icon: app.icon,
            residentBytes: bytes
        )
        items.append(item)
    }

    items.sort { $0.residentBytes > $1.residentBytes }
    if items.count > limit { items.removeSubrange(limit..<items.count) }
    return items
}

/// `libproc` 기반으로 프로세스의 resident memory(bytes)를 읽습니다.
/// - sandbox/MAS 환경에서도 외부 프로세스 실행 없이 동작하도록 하기 위한 방식입니다.
private static func residentMemoryBytes(pid: pid_t) -> Int64? {
    var info = proc_taskinfo()
    let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
    let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expectedSize)
    guard result == expectedSize else { return nil }
    return Int64(info.pti_resident_size)
}


    /// 가벼운 메모리 압박을 통해 OS 가 캐시를 정리하도록 유도
    func performClean(completion: @escaping (MemoryStats, MemoryStats) -> Void) {
        let before = stats
        #if DEBUG
        let mode = cleanFillMode
        #else
        let mode: MemoryCleanFillMode = .pageTouch
        #endif

        DispatchQueue.global(qos: .userInitiated).async {
            MemoryCleaner.performLightClean(totalBytes: before.totalBytes, fillMode: mode)
            Thread.sleep(forTimeInterval: 0.5)
            let after = MemoryReader.fetchStats()

            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.stats = after
                }
                // Clean 이후 앱 메모리 순위도 새로 반영
                self.refreshSignificantApps()
                completion(before, after)
            }
        }
    }

    // MARK: - 내부 포맷터

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
    }
}

/// Native Mach VM 통계(host_statistics64)를 통해 메모리 구성 값을 읽어 MemoryStats 로 변환
enum MemoryReader {
    
    static func fetchStats() -> MemoryStats {
        // host_statistics64(HOST_VM_INFO64) 기반
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var pageSize: vm_size_t = 0
        if host_page_size(host, &pageSize) != KERN_SUCCESS {
            // fallback (거의 발생하지 않음)
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

        guard kr == KERN_SUCCESS else {
            return .empty
        }

        let ps = Int64(pageSize)

        // page counts
        let freePages        = Int64(vmStats.free_count)
        let activePages      = Int64(vmStats.active_count)
        let inactivePages    = Int64(vmStats.inactive_count)
        // speculative_count는 free_count에 포함되는 "free pages"의 부분집합(= speculative)입니다.
        // 따라서 resident(Active/Inactive) 계산에 더하면 double-count가 될 수 있어 제외합니다.
        let speculativePages = Int64(vmStats.speculative_count)
        let wiredPages       = Int64(vmStats.wire_count)
        let compressedPages  = Int64(vmStats.compressor_page_count)
        let fileBackedPages  = Int64(vmStats.external_page_count)   // File-backed pages
        let purgeablePages   = Int64(vmStats.purgeable_count)       // Purgeable pages

        // vm_stat 기반 계산 로직을 유지 (프로세스 호출만 제거)
        // Activity Monitor 개념: Used = (Anonymous + Wired + Compressed)
        _ = speculativePages // (현재는 free_count에 포함되므로 별도 사용하지 않음)

        let totalResident  = activePages + inactivePages
        let anonymousPages = totalResident - fileBackedPages

        let appPages    = max(0, anonymousPages - purgeablePages)
        let cachedPages = fileBackedPages + purgeablePages

        return MemoryStats(
            appBytes:        appPages        * ps,
            wiredBytes:      wiredPages      * ps,
            compressedBytes: compressedPages * ps,
            cachedBytes:     cachedPages     * ps,
            freeBytes:       freePages       * ps
        )
    }
}

private enum MemoryCleaner {
    @inline(never)
    private static func consume(_ value: UInt32) {
        // Release 빌드 최적화에서 버퍼 할당/쓰기 루틴이 통째로 제거되는 것을 방지하기 위한 sink 입니다.
        _ = value
    }

    static func performLightClean(totalBytes: Int64, fillMode: MemoryCleanFillMode) {
        guard totalBytes > 256 * 1024 * 1024 else { return }
        let rawTarget = totalBytes / 5
        let target = min(max(rawTarget, 64 * 1024 * 1024), 1024 * 1024 * 1024)
        let count = Int(target / 4)
        if count <= 0 { return }
        
        // NOTE:
        // - 외부 프로세스/파싱 없이, 메모리 압박을 만들기 위해 큰 버퍼를 할당하고 실제로 "쓰기"를 발생시킵니다.
        // - 기존에는 페이지 단위(step)로 일부만 터치했지만, arc4random_buf로 전체를 빠르게 채우면
        //   커널이 실제 페이지를 더 많이 commit 하게 되어(= 메모리 압박 증가) 캐시/퍼지 유도에 유리합니다.
        // - arc4random_buf는 CSPRNG 기반의 바이트 채우기 API로, 루프 기반 random 대입보다 호출 오버헤드가 낮습니다.

        var buffer = [UInt32](repeating: 0, count: count)
        buffer.withUnsafeMutableBytes { raw in
            guard let baseAddr = raw.baseAddress, raw.count > 0 else { return }

            switch fillMode {
            case .randomFill:
                // 전체 랜덤 채우기: 가장 강한 write 압박
                arc4random_buf(baseAddr, raw.count)

            case .memsetFill(let value):
                // 특정 패턴 채우기: 랜덤이 필요 없고 "전체 페이지 commit"이 목적일 때
                _ = memset(baseAddr, Int32(value), raw.count)

            case .pageTouch:
                // 각 페이지에서 1바이트만 쓰기: 최소 작업량으로 페이지를 touch
                let pageSize = max(4096, Int(sysconf(Int32(_SC_PAGESIZE))))
                let bytes = baseAddr.assumingMemoryBound(to: UInt8.self)
                var offset = 0
                while offset < raw.count {
                    // write를 발생시켜 해당 페이지가 커밋되도록 유도
                    bytes[offset] &+= 1
                    offset += pageSize
                }
            }
        }

        // 일부 값을 읽어 실제로 메모리가 사용되었음을 보장(최적화 방지)
        if !buffer.isEmpty {
            consume(buffer[buffer.count / 2])
        }
    }
}

