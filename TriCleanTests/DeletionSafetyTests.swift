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
    func test_스코프_내부_심볼릭링크가_외부를_가리키면_거부된다() throws {
        let outside = try makeFile(sibling.appendingPathComponent("outside.log"))
        let link = scope.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sibling)
        let escaped = link.appendingPathComponent(outside.lastPathComponent)

        XCTAssertFalse(DeletionSafety.isContained(escaped, inScope: scope))
        let result = DeletionSafety.sanitize([escaped], scope: scope) { $0 }
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejectedCount, 1)
    }

    // MARK: - 심볼릭 링크 없는 실제 경로

    func test_실제_하위경로는_심볼릭링크없음으로_판정한다() throws {
        let file = try makeFile(scope.appendingPathComponent("Developer/DerivedData/Proj/build.log"))
        XCTAssertTrue(DeletionSafety.isFreeOfSymlinks(file, below: scope))
    }

    func test_중간경로가_스코프안의_다른폴더를_가리키는_링크면_거부한다() throws {
        // DerivedData → Application Support/X 처럼 스코프 안을 가리키는 링크는 isContained를 통과한다.
        let realData = scope.appendingPathComponent("Application Support/X", isDirectory: true)
        let precious = try makeFile(realData.appendingPathComponent("db.sqlite"))
        let developer = scope.appendingPathComponent("Developer", isDirectory: true)
        try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
        let derivedData = developer.appendingPathComponent("DerivedData")
        try FileManager.default.createSymbolicLink(at: derivedData, withDestinationURL: realData)
        let viaLink = derivedData.appendingPathComponent(precious.lastPathComponent)

        XCTAssertTrue(DeletionSafety.isContained(viaLink, inScope: scope))
        XCTAssertFalse(DeletionSafety.isFreeOfSymlinks(derivedData, below: scope))
        XCTAssertFalse(DeletionSafety.isFreeOfSymlinks(viaLink, below: scope))
    }

    func test_없는경로와_스코프밖_경로는_거부한다() throws {
        XCTAssertFalse(DeletionSafety.isFreeOfSymlinks(scope.appendingPathComponent("missing/item"), below: scope))
        XCTAssertFalse(DeletionSafety.isFreeOfSymlinks(try makeFile(sibling.appendingPathComponent("a.log")), below: scope))
        XCTAssertFalse(DeletionSafety.isFreeOfSymlinks(scope, below: scope))
    }

    func test_직접_선택한_단일_항목은_exact_정책으로만_허용된다() throws {
        let app = scope.appendingPathComponent("Manual.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        let descendantResult = DeletionSafety.sanitize([app], scope: app) { $0 }
        XCTAssertTrue(descendantResult.accepted.isEmpty)

        let exactResult = DeletionSafety.sanitize(
            [app],
            scopes: [.exact(app)],
            url: { $0 }
        )
        XCTAssertEqual(exactResult.accepted, [app])
        XCTAssertEqual(exactResult.rejectedCount, 0)
    }

}
