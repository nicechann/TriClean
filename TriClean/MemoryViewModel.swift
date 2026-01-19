//
//  MemoryViewModel.swift
//  TriClean
//
//  Created by changyu Kang on 09/12/2025.
//

import Foundation
import Combine
import Darwin       // sysconf
import SwiftUI      // 🔹 withAnimation 을 쓰려면 필요

final class MemoryViewModel: ObservableObject {

    @Published var stats: MemoryStats = .empty
    @Published var displayUnit: MemoryDisplayUnit = .percent

    // MARK: - 공개 계산 값

    var usagePercent: Int {
        let total = max(stats.totalBytes, 1)
        return Int(
            (Double(stats.usedBytes) / Double(total) * 100).rounded()
        )
    }

    var usageText: String {
        "\(usagePercent)%"
    }

    var totalMemoryText: String {
        formatBytes(stats.totalBytes)
    }

    var usedMemoryText: String {
        formatBytes(stats.usedBytes)
    }

    var freeMemoryText: String {
        formatBytes(stats.freeBytes)
    }

    // MARK: - API

    /// vm_stat 를 다시 읽어서 최신 메모리 정보로 갱신
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

    /// 가벼운 메모리 압박을 통해 OS 가 캐시를 정리하도록 유도하고,
    /// 정리 전/후의 실제 vm_stat 값을 completion 으로 반환
    func performClean(completion: @escaping (MemoryStats, MemoryStats) -> Void) {
        let before = stats

        DispatchQueue.global(qos: .userInitiated).async {
            MemoryCleaner.performLightClean(totalBytes: before.totalBytes)

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
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
    }
}

/// vm_stat 를 실행해서 페이지 수를 읽고, MemoryStats 로 변환
enum MemoryReader {
    
    static func fetchStats() -> MemoryStats {
        let pageSize = Int64(sysconf(Int32(_SC_PAGESIZE)))
        let lines = runVMStat()
        
        var values: [String: Int64] = [:]
        
        for line in lines {
            // 예: "Pages free:                               1234."
            let parts = line.components(separatedBy: ":")
            guard parts.count == 2 else { continue }
            
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            
            let numberPart = parts[1]
                .components(separatedBy: CharacterSet.decimalDigits.inverted)
                .joined()
            
            if let v = Int64(numberPart) {
                values[key] = v
            }
        }
        
        func pages(_ key: String) -> Int64 {
            values[key] ?? 0
        }
        
        // vm_stat 기준으로 대략적인 매핑
        let freePages        = pages("Pages free")
        let activePages      = pages("Pages active")
        let speculativePages = pages("Pages speculative")
        let inactivePages    = pages("Pages inactive")
        let wiredPages       = pages("Pages wired down")
        let compressedPages  = pages("Pages occupied by compressor")
        let fileBacked       = pages("File-backed pages")
        let purgeable        = pages("Pages purgeable")
        
        let appPages   = activePages + speculativePages
        let cachedPages = inactivePages + fileBacked + purgeable
        
        return MemoryStats(
            appBytes:        appPages       * pageSize,
            wiredBytes:      wiredPages     * pageSize,
            compressedBytes: compressedPages * pageSize,
            cachedBytes:     cachedPages    * pageSize,
            freeBytes:       freePages      * pageSize
        )
    }
    
    private static func runVMStat() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            return []
        }

        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .map { String($0) }
    }

}

/// 가벼운 메모리 압박을 통해 inactive / cache 등이 정리될 여지를 만드는 유틸리티
private enum MemoryCleaner {

    static func performLightClean(totalBytes: Int64) {
        // 너무 적은 용량이면 굳이 시도하지 않음
        guard totalBytes > 256 * 1024 * 1024 else { return }

        // 전체의 5~10% 정도 선에서 clamp
        let rawTarget = totalBytes / 10
        let target = min(
            max(rawTarget, 64 * 1024 * 1024),     // 최소 64MB
            512 * 1024 * 1024                     // 최대 512MB
        )

        let count = Int(target / 4) // UInt32 기준
        if count <= 0 { return }

        var buffer = [UInt32](repeating: 0, count: count)

        // 페이지를 실제로 touch 해서 OS 가 진짜 메모리를 할당하게 만듦
        let step = max(count / 1024, 1)
        var i = 0
        while i < count {
            buffer[i] = 1
            i += step
        }

        // 함수가 끝나면 buffer 가 해제되면서 OS 가 메모리 회수 기회를 가짐
    }
}
