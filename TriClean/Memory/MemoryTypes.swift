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
    /// 실제 설치된 물리 메모리. 0이면 카테고리 합계로 대체한다.
    var physicalBytes: Int64 = 0

    /// ✅ [수정] 기존에는 카테고리 합계를 총량으로 사용해 speculative 등
    ///   누락분만큼 실제 설치 메모리보다 작게 표시됐다.
    var totalBytes: Int64 {
        physicalBytes > 0 ? physicalBytes : categorySumBytes
    }

    var categorySumBytes: Int64 {
        appBytes + wiredBytes + compressedBytes + cachedBytes + freeBytes
    }

    /// 실제 사용 중으로 표시하는 메모리: App + Wired + Compressed.
    var usedBytes: Int64 {
        min(max(appBytes + wiredBytes + compressedBytes, 0), max(totalBytes, 0))
    }

    /// 총 물리 메모리에서 실제 사용 중 메모리를 뺀 값.
    /// 모든 화면과 메뉴바가 동일한 계산식을 사용합니다.
    var availableBytes: Int64 {
        max(totalBytes - usedBytes, 0)
    }

    static let empty = MemoryStats(
        appBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        cachedBytes: 0,
        freeBytes: 0
    )
}

