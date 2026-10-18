//
//  JunkSelectionScopeTests.swift
//  TriCleanTests
//
//  카테고리 선택 상태와 카테고리 단독 정리 범위의 회귀를 방지한다.
//

import XCTest
@testable import TriClean

final class JunkSelectionScopeTests: XCTestCase {

    func test_선택상태는_없음_일부_전체를_구분한다() {
        XCTAssertEqual(makeResult(id: "none", selected: [false, false]).selectionState, .none)
        XCTAssertEqual(makeResult(id: "partial", selected: [true, false]).selectionState, .partial)
        XCTAssertEqual(makeResult(id: "all", selected: [true, true]).selectionState, .all)
    }

    func test_카테고리토글은_일부선택에서_전체선택후_전체해제한다() {
        var result = makeResult(id: "cache", selected: [true, false, false])

        result.toggleAllSelection()
        XCTAssertEqual(result.selectionState, .all)
        XCTAssertTrue(result.items.allSatisfy(\.isSelected))

        result.toggleAllSelection()
        XCTAssertEqual(result.selectionState, .none)
        XCTAssertTrue(result.items.allSatisfy { !$0.isSelected })
    }

    func test_카테고리정리후보는_해당카테고리의_선택항목만_포함한다() {
        let cache = makeResult(id: "cache", selected: [true, false, true])
        let logs = makeResult(id: "logs", selected: [true, true])

        let selected = JunkScannerViewModel.selectedItems(
            in: [cache, logs],
            categoryID: "cache"
        )

        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(selected.allSatisfy { $0.categoryID == "cache" })
    }

    func test_전체정리후보는_모든카테고리의_선택항목을_포함한다() {
        let cache = makeResult(id: "cache", selected: [true, false, true])
        let logs = makeResult(id: "logs", selected: [false, true])

        let selected = JunkScannerViewModel.selectedItems(in: [cache, logs])

        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(Set(selected.map(\.categoryID)), ["cache", "logs"])
    }

    func test_카테고리정리대상은_확인창과_같은범위만_포함한다() {
        let cache = makeResult(id: "cache", selected: [true, false, true])
        let logs = makeResult(id: "logs", selected: [true, true])

        let targets = JunkScannerViewModel.cleanTargets(in: [cache, logs], categoryID: "cache")
        let confirmed = JunkScannerViewModel.selectedItems(in: [cache, logs], categoryID: "cache")

        XCTAssertEqual(targets.map(\.id), confirmed.map(\.id))
        XCTAssertEqual(Set(targets.map(\.id)), Set(cache.items.filter(\.isSelected).map(\.id)))
    }

    func test_전체정리대상은_카테고리별_재검증정책을_유지한다() {
        let cache = makeResult(
            id: "cache",
            selected: [true],
            policy: .allowDirectoryContentChanges
        )
        let state = makeResult(id: "state", selected: [true], policy: .strict)

        let targets = JunkScannerViewModel.cleanTargets(in: [cache, state])
        let policyByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.identityValidationPolicy) })

        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(policyByID[cache.items[0].id], .allowDirectoryContentChanges)
        XCTAssertEqual(policyByID[state.items[0].id], .strict)
    }

    func test_목록은_기본30개와_전체보기를_전환한다() {
        let result = makeResult(id: "cache", selected: Array(repeating: true, count: 37))

        XCTAssertEqual(result.displayedItems(showAll: false).count, 30)
        XCTAssertEqual(result.displayedItems(showAll: true).count, 37)
    }

    private func makeResult(
        id: String,
        selected: [Bool],
        policy: JunkCategory.IdentityValidationPolicy = .strict
    ) -> JunkScanResult {
        let category = JunkCategory(
            id: id,
            name: id,
            icon: "doc",
            description: id,
            relativePaths: [id],
            identityValidationPolicy: policy,
            riskLevel: .safe
        )
        let items = selected.enumerated().map { index, isSelected in
            JunkItem(
                url: URL(fileURLWithPath: "/tmp/\(id)-\(index)"),
                sizeBytes: Int64(index + 1),
                categoryID: id,
                fileIdentity: nil,
                isSelected: isSelected
            )
        }
        return JunkScanResult(id: id, category: category, items: items)
    }
}
