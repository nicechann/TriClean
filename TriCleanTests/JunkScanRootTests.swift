//
//  JunkScanRootTests.swift
//  TriCleanTests
//
//  정크 정리 대상은 자신을 찾은 카테고리 경로의 "실제" 하위 항목이어야 한다.
//  카테고리 경로가 Library 안의 다른 폴더를 가리키는 링크면 ~/Library 경계 검사만으로는 막지 못한다.
//

import XCTest
@testable import TriClean

final class JunkScanRootTests: XCTestCase {

    private var library: URL!

    override func setUpWithError() throws {
        library = FileManager.default.temporaryDirectory
            .appendingPathComponent("JunkScanRootTests-\(UUID().uuidString)")
            .appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: library.deletingLastPathComponent())
    }

    private func target(_ url: URL, root: URL) -> JunkScannerViewModel.CleanTarget {
        JunkScannerViewModel.CleanTarget(
            id: UUID(),
            url: url,
            scanRoot: root,
            fileIdentity: nil,
            identityValidationPolicy: .strict
        )
    }

    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = library.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_카테고리경로의_바로아래_실제항목은_허용한다() throws {
        let caches = try makeDirectory("Caches")
        let child = try makeDirectory("Caches/com.example.app")

        XCTAssertTrue(JunkScannerViewModel.isWithinRealScanRoot(target(child, root: caches), library: library))
    }

    func test_카테고리경로_자신인_단일파일은_허용한다() throws {
        let logs = try makeDirectory("Logs")
        let file = logs.appendingPathComponent("single.log")
        try Data("log".utf8).write(to: file)

        XCTAssertTrue(JunkScannerViewModel.isWithinRealScanRoot(target(file, root: file), library: library))
    }

    func test_카테고리경로보다_깊은항목은_거부한다() throws {
        let caches = try makeDirectory("Caches")
        let grandchild = try makeDirectory("Caches/com.example.app/nested")

        XCTAssertFalse(JunkScannerViewModel.isWithinRealScanRoot(target(grandchild, root: caches), library: library))
    }

    func test_카테고리경로가_다른폴더를_가리키는_링크면_거부한다() throws {
        let precious = try makeDirectory("Application Support/X")
        _ = try makeDirectory("Application Support/X/Database")
        let developer = try makeDirectory("Developer/Xcode")
        let derivedData = developer.appendingPathComponent("DerivedData")
        try FileManager.default.createSymbolicLink(at: derivedData, withDestinationURL: precious)
        let viaLink = derivedData.appendingPathComponent("Database")

        XCTAssertFalse(JunkScannerViewModel.isWithinRealScanRoot(target(viaLink, root: derivedData), library: library))
    }

    // MARK: - 재스캔 시 선택 이어받기

    private func result(_ id: String, _ items: [(String, Bool)]) -> JunkScanResult {
        let category = JunkCategory(
            id: id,
            name: id,
            icon: "doc",
            description: id,
            relativePaths: [id],
            riskLevel: .safe
        )
        return JunkScanResult(id: id, category: category, items: items.map { path, selected in
            JunkItem(
                url: URL(fileURLWithPath: path),
                sizeBytes: 2048,
                categoryID: id,
                isSelected: selected
            )
        })
    }

    func test_재스캔하면_이전에_해제한_항목은_해제상태를_유지한다() {
        let before = result("cache", [("/L/Caches/a", false), ("/L/Caches/b", true)])
        // 새 스캔은 카테고리 기본값(모두 선택)으로 채워지고, 새 항목 c가 생겼다.
        let rescanned = result("cache", [("/L/Caches/a", true), ("/L/Caches/b", true), ("/L/Caches/c", true)])

        let carried = JunkScannerViewModel.carryOverSelections(
            JunkScannerViewModel.selectionByPath(in: [before]),
            into: [rescanned]
        )

        let selection = Dictionary(uniqueKeysWithValues: carried[0].items.map { ($0.path, $0.isSelected) })
        XCTAssertEqual(selection["/L/Caches/a"], false)
        XCTAssertEqual(selection["/L/Caches/b"], true)
        XCTAssertEqual(selection["/L/Caches/c"], true)
    }
}
