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

    func test_일반캐시에서_Safari전용경로를_제외한다() throws {
        let category = try XCTUnwrap(
            JunkCategory.defaultCategories.first { $0.id == "system_caches" }
        )

        XCTAssertEqual(
            category.excludedChildNames,
            ["com.apple.Safari", "com.apple.Safari.SafeBrowsing"]
        )
    }

    func test_일반로그에서_충돌보고서경로를_제외한다() throws {
        let category = try XCTUnwrap(
            JunkCategory.defaultCategories.first { $0.id == "system_logs" }
        )

        XCTAssertEqual(
            category.excludedChildNames,
            ["DiagnosticReports", "CrashReporter"]
        )
    }

    func test_동적캐시와로그카테고리는_디렉터리내용변경을_허용한다() throws {
        let dynamicIDs: Set<String> = [
            "system_caches",
            "system_logs",
            "xcode_derived",
            "safari_cache",
            "crash_reports",
            "http_storage"
        ]

        for category in JunkCategory.defaultCategories where dynamicIDs.contains(category.id) {
            XCTAssertEqual(
                category.identityValidationPolicy,
                .allowDirectoryContentChanges,
                "\(category.id)는 실행 중 내용이 바뀔 수 있는 디렉터리를 포함합니다."
            )
        }
    }

    func test_사용자보관데이터카테고리는_엄격검증을_유지한다() throws {
        let strictIDs: Set<String> = [
            "xcode_archives",
            "mail_downloads",
            "saved_app_state"
        ]

        for category in JunkCategory.defaultCategories where strictIDs.contains(category.id) {
            XCTAssertEqual(category.identityValidationPolicy, .strict)
        }
    }

    func test_정크카테고리끼리_상위하위경로가_중복되지_않는다() {
        let categories = JunkCategory.defaultCategories

        for ancestorCategory in categories {
            for ancestorPath in ancestorCategory.relativePaths {
                let ancestorComponents = pathComponents(ancestorPath)

                for descendantCategory in categories where descendantCategory.id != ancestorCategory.id {
                    for descendantPath in descendantCategory.relativePaths {
                        let descendantComponents = pathComponents(descendantPath)

                        if descendantComponents == ancestorComponents {
                            XCTFail(
                                "\(ancestorCategory.id)와 \(descendantCategory.id)가 같은 경로 \(ancestorPath)을 중복 등록했습니다."
                            )
                            continue
                        }

                        guard descendantComponents.count > ancestorComponents.count,
                              descendantComponents.starts(with: ancestorComponents)
                        else { continue }

                        let directChildName = descendantComponents[ancestorComponents.count]
                        XCTAssertTrue(
                            ancestorCategory.excludedChildNames.contains(directChildName),
                            "\(ancestorCategory.id): \(ancestorPath)에서 별도 카테고리 경로 \(descendantPath)의 직계 하위 \(directChildName)을 제외해야 합니다."
                        )
                    }
                }
            }
        }
    }

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

}
