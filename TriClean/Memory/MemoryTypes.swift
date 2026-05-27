//
//  MemoryTypes.swift
//  TriClean
//
//  Created by changyu Kang on 10/12/2025.
//

import Foundation
import SwiftUI

/// 메모리 표시 단위: % / MB
nonisolated enum MemoryDisplayUnit: String, CaseIterable, Identifiable, Sendable {
    case percent
    case megabytes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percent:   return "%"
        case .megabytes: return "MB"
        }
    }
}

/// macOS Mach VM 통계(host_statistics64)를 기반으로 구성한 메모리 구성 값
nonisolated struct MemoryStats: Sendable {
    var appBytes: Int64        // 활성/사용 중 메모리
    var wiredBytes: Int64      // Wired
    var compressedBytes: Int64 // Compressed
    var cachedBytes: Int64     // 파일 캐시, inactive 등
    var freeBytes: Int64       // Free

    var totalBytes: Int64 {
        appBytes + wiredBytes + compressedBytes + cachedBytes + freeBytes
    }

    var usedBytes: Int64 {
        totalBytes - freeBytes
    }

    static let empty = MemoryStats(
        appBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        cachedBytes: 0,
        freeBytes: 0
    )
}

