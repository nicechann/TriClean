//
//  JunkCategory.swift
//  TriClean
//
//  macOS에서 안전하게 정리할 수 있는 정크 파일 카테고리 정의
//
//  참고: 샌드박스 앱에서는 Security-Scoped Bookmark으로
//  ~/Library 접근 권한을 받아야 합니다.
//

import Foundation
import SwiftUI

struct JunkCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let relativePaths: [String]
    let riskLevel: RiskLevel

    enum RiskLevel: String, CaseIterable {
        case safe
        case moderate
        case caution

        var color: Color {
            switch self {
            case .safe:     return Color(red: 0.43, green: 0.84, blue: 0.41)
            case .moderate: return Color(red: 0.99, green: 0.71, blue: 0.31)
            case .caution:  return Color(red: 0.98, green: 0.46, blue: 0.33)
            }
        }

        var label: String {
            switch self {
            case .safe:     return "junk.risk.safe".localized
            case .moderate: return "junk.risk.moderate".localized
            case .caution:  return "junk.risk.caution".localized
            }
        }

        nonisolated var defaultSelected: Bool {
            self == .safe
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: JunkCategory, rhs: JunkCategory) -> Bool {
        lhs.id == rhs.id
    }
}

struct JunkItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let sizeBytes: Int64
    let categoryID: String
    var isSelected: Bool

    nonisolated init(id: UUID = UUID(), url: URL, sizeBytes: Int64, categoryID: String, isSelected: Bool = true) {
        self.id = id
        self.url = url
        self.sizeBytes = sizeBytes
        self.categoryID = categoryID
        self.isSelected = isSelected
    }

    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: JunkItem, rhs: JunkItem) -> Bool { lhs.id == rhs.id }
}

struct JunkScanResult: Identifiable {
    let id: String
    let category: JunkCategory
    var items: [JunkItem]

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    var selectedBytes: Int64 { items.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes } }
    var totalString: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

extension JunkCategory {
    static let defaultCategories: [JunkCategory] = [
        JunkCategory(
            id: "system_caches",
            name: "junk.category.system_caches.title".localized,
            icon: "archivebox",
            description: "junk.category.system_caches.desc".localized,
            relativePaths: ["Caches"],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "system_logs",
            name: "junk.category.system_logs.title".localized,
            icon: "doc.text",
            description: "junk.category.system_logs.desc".localized,
            relativePaths: ["Logs"],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "xcode_derived",
            name: "junk.category.xcode_derived.title".localized,
            icon: "hammer",
            description: "junk.category.xcode_derived.desc".localized,
            relativePaths: ["Developer/Xcode/DerivedData"],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "xcode_archives",
            name: "junk.category.xcode_archives.title".localized,
            icon: "shippingbox",
            description: "junk.category.xcode_archives.desc".localized,
            relativePaths: ["Developer/Xcode/Archives"],
            riskLevel: .moderate
        ),
        JunkCategory(
            id: "safari_cache",
            name: "junk.category.safari_cache.title".localized,
            icon: "safari",
            description: "junk.category.safari_cache.desc".localized,
            relativePaths: [
                "Caches/com.apple.Safari",
                "Caches/com.apple.Safari.SafeBrowsing"
            ],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "mail_downloads",
            name: "junk.category.mail_downloads.title".localized,
            icon: "envelope",
            description: "junk.category.mail_downloads.desc".localized,
            relativePaths: [
                "Containers/com.apple.mail/Data/Library/Mail Downloads"
            ],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "saved_app_state",
            name: "junk.category.saved_app_state.title".localized,
            icon: "clock.arrow.circlepath",
            description: "junk.category.saved_app_state.desc".localized,
            relativePaths: ["Saved Application State"],
            riskLevel: .moderate
        ),
        JunkCategory(
            id: "crash_reports",
            name: "junk.category.crash_reports.title".localized,
            icon: "exclamationmark.triangle",
            description: "junk.category.crash_reports.desc".localized,
            relativePaths: [
                "Logs/DiagnosticReports",
                "Logs/CrashReporter"
            ],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "webkit_cache",
            name: "junk.category.webkit_cache.title".localized,
            icon: "globe",
            description: "junk.category.webkit_cache.desc".localized,
            relativePaths: ["WebKit"],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "http_storage",
            name: "junk.category.http_storage.title".localized,
            icon: "network",
            description: "junk.category.http_storage.desc".localized,
            relativePaths: ["HTTPStorages"],
            riskLevel: .moderate
        ),
    ]
}
