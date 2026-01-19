//
//  MemoryViewModel.swift
//  TriClean
//
//  Created by changyu Kang on 09/12/2025.
//

import Foundation
import Combine
import Darwin       // sysconf
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
            let parts = line.components(separatedBy: ":")
            guard parts.count == 2 else { continue }
            
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let numberPart = parts[1]
               .trimmingCharacters(in: .whitespacesAndNewlines)
               .replacingOccurrences(of: ".", with: "")
            
            if let v = Int64(numberPart) {
                values[key] = v
            }
        }
        
        func pages(_ key: String) -> Int64 {
            values[key] ?? 0
        }
        
        let freePages        = pages("Pages free")
        let activePages      = pages("Pages active")
        let speculativePages = pages("Pages speculative")
        let inactivePages    = pages("Pages inactive")
        let wiredPages       = pages("Pages wired down")
        let compressedPages  = pages("Pages occupied by compressor")
        let fileBacked       = pages("File-backed pages")
        let purgeable        = pages("Pages purgeable")
        
        // Activity Monitor 로직: Used = (Anonymous + Wired + Compressed)
        let totalResident = activePages + inactivePages + speculativePages
        let anonymousPages = totalResident - fileBacked
        
        let appPages = max(0, anonymousPages - purgeable)
        let cachedPages = fileBacked + purgeable
        
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
