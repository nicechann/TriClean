//
//  DeletionSafetyTests.swift
//  TriCleanTests
//
//  삭제 대상 경로 검증은 잘못되면 사용자 데이터 손실로 직결되므로
//  실제 파일 시스템(임시 디렉터리)을 사용해 검증한다.
//

import XCTest
@testable import TriClean

final class DeletionSafetyTests: XCTestCase {

    private var base: URL!
    private var scope: URL!
    private var sibling: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeletionSafetyTests-\(UUID().uuidString)")
        scope = base.appendingPathComponent("Library")
        sibling = base.appendingPathComponent("Library2")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    private func makeFile(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: url)
        return url
    }

    // MARK: - 경계 검사

    func test_스코프_하위_경로는_허용된다() throws {
        let file = try makeFile(scope.appendingPathComponent("Caches/app.log"))
        XCTAssertTrue(DeletionSafety.isContained(file, inScope: scope))
    }

    /// 단순 hasPrefix 구현에서 실제로 통과하던 케이스.
    /// `/…/Library2`는 `/…/Library`의 하위가 아니다.
    func test_접두어만_같은_형제_폴더는_거부된다() throws {
        let file = try makeFile(sibling.appendingPathComponent("app.log"))
        XCTAssertFalse(DeletionSafety.isContained(file, inScope: scope))
    }

    func test_스코프_루트_자체는_거부된다() {
        XCTAssertFalse(DeletionSafety.isContained(scope, inScope: scope))
    }

    func test_스코프_상위_경로는_거부된다() throws {
        let file = try makeFile(base.appendingPathComponent("outside.log"))
        XCTAssertFalse(DeletionSafety.isContained(file, inScope: scope))
    }

    func test_상대경로_탈출은_거부된다() throws {
        try makeFile(sibling.appendingPathComponent("escaped.log"))
        let traversal = scope.appendingPathComponent("../Library2/escaped.log")
        XCTAssertFalse(DeletionSafety.isContained(traversal, inScope: scope))
    }

    // MARK: - sanitize

    func test_존재하지_않는_경로는_제외된다() throws {
        let present = try makeFile(scope.appendingPathComponent("a.log"))
        let missing = scope.appendingPathComponent("gone.log")

        let (accepted, rejected) = DeletionSafety.sanitize([present, missing], scope: scope) { $0 }

        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(rejected, 1)
        XCTAssertEqual(accepted.first?.lastPathComponent, "a.log")
    }

    func test_스코프_밖_경로는_제외된다() throws {
        let inside = try makeFile(scope.appendingPathComponent("a.log"))
        let outside = try makeFile(sibling.appendingPathComponent("b.log"))

        let (accepted, rejected) = DeletionSafety.sanitize([inside, outside], scope: scope) { $0 }

        XCTAssertEqual(accepted.map(\.path), [inside.path])
        XCTAssertEqual(rejected, 1)
    }

    func test_중복_경로는_한_번만_남는다() throws {
        let file = try makeFile(scope.appendingPathComponent("a.log"))
        let same = scope.appendingPathComponent("./a.log")

        let (accepted, rejected) = DeletionSafety.sanitize([file, same], scope: scope) { $0 }

        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(rejected, 1)
    }

    func test_모두_무효하면_빈_배열을_반환한다() {
        let ghosts = [
            scope.appendingPathComponent("x.log"),
            sibling.appendingPathComponent("y.log")
        ]
        let (accepted, rejected) = DeletionSafety.sanitize(ghosts, scope: scope) { $0 }

        XCTAssertTrue(accepted.isEmpty)
        XCTAssertEqual(rejected, 2)
    }
}
