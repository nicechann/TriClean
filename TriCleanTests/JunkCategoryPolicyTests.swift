//
//  JunkCategoryPolicyTests.swift
//  TriCleanTests
//
//  사용자 데이터가 포함될 수 있는 정크 카테고리가
//  안전 항목으로 기본 선택되는 회귀를 방지한다.
//

import XCTest
@testable import TriClean

final class JunkCategoryPolicyTests: XCTestCase {

    func test_mailDownloads는_기본선택되지_않는다() throws {
        let category = try XCTUnwrap(
            JunkCategory.defaultCategories.first { $0.id == "mail_downloads" }
        )

        XCTAssertEqual(category.riskLevel, .moderate)
        XCTAssertFalse(category.riskLevel.defaultSelected)
    }

    func test_webKit전체폴더는_정크카테고리에_포함하지_않는다() {
        XCTAssertFalse(
            JunkCategory.defaultCategories.contains { $0.id == "webkit_cache" }
        )
        XCTAssertFalse(
            JunkCategory.defaultCategories
                .flatMap(\.relativePaths)
                .contains("WebKit")
        )
    }

    func test_safe등급만_기본선택된다() {
        for riskLevel in JunkCategory.RiskLevel.allCases {
            XCTAssertEqual(riskLevel.defaultSelected, riskLevel == .safe)
        }
    }
}
