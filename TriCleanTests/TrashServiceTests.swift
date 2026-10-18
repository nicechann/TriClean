//
//  TrashServiceTests.swift
//  TriCleanTests
//
//  모든 화면의 실제 삭제가 거치는 TrashService 루프를 검증한다.
//  사용자 휴지통을 건드리지 않도록 이동 수단(Mover)만 임시 폴더로 바꾸고,
//  재검증 순서·집계는 프로덕션 코드 그대로 실행한다.
//

import XCTest
@testable import TriClean

final class TrashServiceTests: XCTestCase {
    private struct Target: Sendable {
        let url: URL
        let identity: FileIdentitySnapshot?
        var allowsContentChanges = false
    }

    private struct FakeTrashError: Error {}

    private var root: URL!
    private var fakeTrash: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashServiceTests-\(UUID().uuidString)")
        root = base.appendingPathComponent("scope", isDirectory: true)
        fakeTrash = base.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: - Helpers

    private func makeFile(_ name: String, _ content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func target(_ url: URL, allowsContentChanges: Bool = false) -> Target {
        Target(
            url: url,
            identity: FileIdentitySnapshot.captureItem(url),
            allowsContentChanges: allowsContentChanges
        )
    }

    /// 대상을 임시 휴지통 폴더로 옮기는 이동 수단. 폴백(recycle)이 불리면 테스트 실패로 본다.
    private func movingMover(
        beforeMove: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) -> TrashService.Mover {
        let trash: URL = fakeTrash
        return TrashService.Mover(
            trashItem: { url in
                try beforeMove(url)
                try FileManager.default.moveItem(
                    at: url,
                    to: trash.appendingPathComponent(UUID().uuidString)
                )
            },
            recycle: { url in
                XCTFail("recycle fallback should not run for \(url.lastPathComponent)")
                return nil
            }
        )
    }

    private func move(
        _ targets: [Target],
        mover: TrashService.Mover
    ) async -> TrashService.Outcome<Target> {
        await TrashService.moveToTrash(
            targets,
            url: \.url,
            identity: \.identity,
            allowsDirectoryContentChanges: \.allowsContentChanges,
            logCategory: "TrashServiceTests",
            mover: mover
        )
    }

    // MARK: - Tests

    func test_정체성이_그대로인_항목만_이동한다() async throws {
        let file = try makeFile("keep-identity.dat", "data")

        let outcome = await move([target(file)], mover: movingMover())

        XCTAssertEqual(outcome.succeededCount, 1)
        XCTAssertEqual(outcome.excludedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test_스캔후_내용이_바뀐_파일은_이동하지_않고_제외한다() async throws {
        let file = try makeFile("edited.dat", "old")
        let scanned = target(file)
        try Data("edited content".utf8).write(to: file)

        let outcome = await move([scanned], mover: movingMover())

        XCTAssertEqual(outcome.succeededCount, 0)
        XCTAssertEqual(outcome.excludedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func test_정체성정보가_없으면_이동하지_않는다() async throws {
        let file = try makeFile("no-identity.dat", "data")

        let outcome = await move([Target(url: file, identity: nil)], mover: movingMover())

        XCTAssertEqual(outcome.excludedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func test_앞항목을_처리하는_사이_뒤항목이_교체되면_루프안에서_거부한다() async throws {
        let first = try makeFile("first.dat", "first")
        let second = try makeFile("second.dat", "second-old")
        let targets = [target(first), target(second)]

        // 첫 번째 항목을 옮기는 동안 두 번째 경로가 새 파일로 교체된 상황.
        let mover = movingMover { url in
            guard url.lastPathComponent == "first.dat" else { return }
            try FileManager.default.removeItem(at: second)
            try Data("second-new-content".utf8).write(to: second)
        }

        let outcome = await move(targets, mover: mover)

        XCTAssertEqual(outcome.succeeded.map(\.url.lastPathComponent), ["first.dat"])
        XCTAssertEqual(outcome.excluded.map(\.url.lastPathComponent), ["second.dat"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func test_이동실패후_항목이_바뀌면_폴백하지_않고_제외한다() async throws {
        let file = try makeFile("changed-after-failure.dat", "old")

        let mover = TrashService.Mover(
            trashItem: { url in
                try Data("rewritten by app".utf8).write(to: url)
                throw FakeTrashError()
            },
            recycle: { url in
                XCTFail("recycle fallback must not run after identity changed: \(url.lastPathComponent)")
                return nil
            }
        )

        let outcome = await move([target(file)], mover: mover)

        XCTAssertEqual(outcome.excludedCount, 1)
        XCTAssertEqual(outcome.failedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func test_이동실패후_항목이_그대로면_폴백결과로_집계한다() async throws {
        let ok = try makeFile("fallback-ok.dat", "a")
        let ng = try makeFile("fallback-ng.dat", "b")

        let mover = TrashService.Mover(
            trashItem: { _ in throw FakeTrashError() },
            recycle: { url in
                guard url.lastPathComponent == "fallback-ng.dat" else { return nil }
                return TrashService.Failure(url: url, error: FakeTrashError())
            }
        )

        let outcome = await move([target(ok), target(ng)], mover: mover)

        XCTAssertEqual(outcome.succeeded.map(\.url.lastPathComponent), ["fallback-ok.dat"])
        XCTAssertEqual(outcome.failed.map(\.url.lastPathComponent), ["fallback-ng.dat"])
        XCTAssertEqual(outcome.firstFailure?.path, ng.standardizedFileURL.path)
    }

    func test_폴더내용변경허용은_폴더에만_적용된다() async throws {
        let strictFolder = root.appendingPathComponent("strict", isDirectory: true)
        let cacheFolder = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: strictFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let targets = [
            target(strictFolder),
            target(cacheFolder, allowsContentChanges: true)
        ]

        // 스캔 이후 두 폴더 모두에 새 파일이 생겼다(폴더 mtime 변경).
        try Data("new".utf8).write(to: strictFolder.appendingPathComponent("new.dat"))
        try Data("new".utf8).write(to: cacheFolder.appendingPathComponent("new.dat"))

        let outcome = await move(targets, mover: movingMover())

        XCTAssertEqual(outcome.succeeded.map(\.url.lastPathComponent), ["cache"])
        XCTAssertEqual(outcome.excluded.map(\.url.lastPathComponent), ["strict"])
    }

    func test_스코프밖_항목은_이동을_시도하지_않는다() async throws {
        let inside = try makeFile("inside.dat", "in")
        let outside = fakeTrash.deletingLastPathComponent().appendingPathComponent("outside.dat")
        try Data("out".utf8).write(to: outside)

        let outcome = await TrashService.sanitizeAndMoveToTrash(
            [target(inside), target(outside)],
            scopes: [.descendants(of: root)],
            url: \.url,
            identity: \.identity,
            logCategory: "TrashServiceTests",
            mover: movingMover()
        )

        XCTAssertEqual(outcome.succeeded.map(\.url.lastPathComponent), ["inside.dat"])
        XCTAssertEqual(outcome.excluded.map(\.url.lastPathComponent), ["outside.dat"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
