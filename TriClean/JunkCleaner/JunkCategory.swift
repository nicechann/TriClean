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

// MARK: - 정크 카테고리

struct JunkCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let relativePaths: [String]  // ~/Library 기준 상대 경로
    let riskLevel: RiskLevel
    
    enum RiskLevel: String, CaseIterable {
        case safe       // 삭제해도 100% 안전
        case moderate   // 앱 재시작 시 재생성됨
        case caution    // 설정이 초기화될 수 있음
        
        var color: Color {
            switch self {
            case .safe:     return Color(red: 0.43, green: 0.84, blue: 0.41)
            case .moderate: return Color(red: 0.99, green: 0.71, blue: 0.31)
            case .caution:  return Color(red: 0.98, green: 0.46, blue: 0.33)
            }
        }
        
        var label: String {
            switch self {
            case .safe:     return "Safe"
            case .moderate: return "Moderate"
            case .caution:  return "Caution"
            }
        }
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: JunkCategory, rhs: JunkCategory) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 스캔 결과

struct JunkItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let sizeBytes: Int64
    let categoryID: String
    var isSelected: Bool = true
    
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: JunkItem, rhs: JunkItem) -> Bool { lhs.id == rhs.id }
}

struct JunkScanResult: Identifiable {
    let id: String  // categoryID
    let category: JunkCategory
    var items: [JunkItem]
    
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    var selectedBytes: Int64 { items.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes } }
    var totalString: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

// MARK: - 기본 카테고리 정의

extension JunkCategory {
    
    /// macOS에서 안전하게 정리 가능한 정크 카테고리 목록
    static let defaultCategories: [JunkCategory] = [
        JunkCategory(
            id: "system_caches",
            name: "System Caches",
            icon: "archivebox",
            description: "앱과 시스템이 생성한 캐시 파일. 삭제해도 앱 재시작 시 자동 재생성됩니다.",
            relativePaths: ["Caches"],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "system_logs",
            name: "System Logs",
            icon: "doc.text",
            description: "앱과 시스템 로그 파일. 디버깅 용도로만 필요합니다.",
            relativePaths: ["Logs"],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "xcode_derived",
            name: "Xcode DerivedData",
            icon: "hammer",
            description: "Xcode 빌드 캐시. 개발자가 아니라면 불필요합니다.",
            relativePaths: ["Developer/Xcode/DerivedData"],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "xcode_archives",
            name: "Xcode Archives",
            icon: "shippingbox",
            description: "Xcode 앱 아카이브. 이전 빌드를 보관하지 않는다면 삭제 가능합니다.",
            relativePaths: ["Developer/Xcode/Archives"],
            riskLevel: .moderate
        ),
        JunkCategory(
            id: "safari_cache",
            name: "Safari Cache",
            icon: "safari",
            description: "Safari 브라우저 캐시. 삭제 시 웹 페이지 로딩이 일시적으로 느려질 수 있습니다.",
            relativePaths: [
                "Caches/com.apple.Safari",
                "Caches/com.apple.Safari.SafeBrowsing"
            ],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "mail_downloads",
            name: "Mail Downloads",
            icon: "envelope",
            description: "Mail 앱이 다운로드한 첨부파일 캐시.",
            relativePaths: [
                "Containers/com.apple.mail/Data/Library/Mail Downloads"
            ],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "saved_app_state",
            name: "Saved App State",
            icon: "clock.arrow.circlepath",
            description: "앱이 마지막으로 열려있던 창/탭 상태. 삭제 시 앱이 기본 상태로 시작됩니다.",
            relativePaths: ["Saved Application State"],
            riskLevel: .moderate
        ),
        JunkCategory(
            id: "crash_reports",
            name: "Crash Reports",
            icon: "exclamationmark.triangle",
            description: "앱 크래시 리포트. 디버깅이 필요 없다면 삭제해도 됩니다.",
            relativePaths: [
                "Logs/DiagnosticReports",
                "Logs/CrashReporter"
            ],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "webkit_cache",
            name: "WebKit Cache",
            icon: "globe",
            description: "WebKit 기반 앱(Safari 등)의 캐시 데이터.",
            relativePaths: ["WebKit"],
            riskLevel: .safe
        ),
        JunkCategory(
            id: "http_storage",
            name: "HTTP Storage",
            icon: "network",
            description: "앱의 HTTP 캐시 및 쿠키 저장소.",
            relativePaths: ["HTTPStorages"],
            riskLevel: .moderate
        ),
    ]
}
