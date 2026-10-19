//
//  ItemSizeTests.swift
//  TriCleanTests
//
//  정크·앱 잔여 파일은 폴더째 휴지통으로 간다. 표시 크기는 실제 이동 범위(숨김 항목 포함)와
//  같아야 하고, 심볼릭 링크를 따라가 외부 경로의 크기를 더하면 안 된다.
//

import XCTest
@testable import TriClean

final class ItemSizeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ItemSizeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        return url
    }

    func test_숨김파일도_폴더크기에_포함한다() throws {
        try write("Cache/visible.bin", bytes: 64 * 1024)
        let withoutHidden = ItemSize.allocatedBytes(at: root.appendingPathComponent("Cache"))

        try write("Cache/.hidden.bin", bytes: 256 * 1024)
        let withHidden = ItemSize.allocatedBytes(at: root.appendingPathComponent("Cache"))

        XCTAssertGreaterThanOrEqual(withHidden - withoutHidden, 256 * 1024)
    }

    func test_숨김폴더_git도_상위폴더크기에_포함한다() throws {
        try write("Project/readme.txt", bytes: 1024)
        let before = ItemSize.allocatedBytes(at: root.appendingPathComponent("Project"))

        try write("Project/.git/objects/pack/pack-1.pack", bytes: 512 * 1024)
        let after = ItemSize.allocatedBytes(at: root.appendingPathComponent("Project"))

        XCTAssertGreaterThanOrEqual(after - before, 512 * 1024)
    }

    func test_하위의_심볼릭링크는_따라가지_않는다() throws {
        try write("External/huge.bin", bytes: 1024 * 1024)
        try write("Cache/small.bin", bytes: 4 * 1024)
        let cache = root.appendingPathComponent("Cache")
        let before = ItemSize.allocatedBytes(at: cache)

        try FileManager.default.createSymbolicLink(
            at: cache.appendingPathComponent("link-to-external"),
            withDestinationURL: root.appendingPathComponent("External")
        )
        try FileManager.default.createSymbolicLink(
            at: cache.appendingPathComponent("link-to-file"),
            withDestinationURL: root.appendingPathComponent("External/huge.bin")
        )

        XCTAssertEqual(ItemSize.allocatedBytes(at: cache), before)
    }

    func test_대상자신이_심볼릭링크면_0이다() throws {
        try write("External/huge.bin", bytes: 1024 * 1024)
        let link = root.appendingPathComponent("LinkedCache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("External"))

        XCTAssertEqual(ItemSize.allocatedBytes(at: link), 0)
    }

    func test_단일파일은_할당크기를_반환한다() throws {
        let file = try write("single.log", bytes: 10_000)
        XCTAssertGreaterThanOrEqual(ItemSize.allocatedBytes(at: file), 10_000)
    }
}
