//
//  FileIdentitySnapshotTests.swift
//  TriCleanTests
//

import XCTest
@testable import TriClean

final class FileIdentitySnapshotTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileIdentitySnapshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_같은_파일은_스냅샷과_일치한다() throws {
        let url = root.appendingPathComponent("same.dat")
        try Data("original".utf8).write(to: url)

        let snapshot = try XCTUnwrap(FileIdentitySnapshot.capture(url))

        XCTAssertTrue(snapshot.matchesCurrentFile(at: url))
    }

    func test_같은_경로의_파일을_교체하면_일치하지_않는다() throws {
        let url = root.appendingPathComponent("replaced.dat")
        try Data("original".utf8).write(to: url)
        let snapshot = try XCTUnwrap(FileIdentitySnapshot.capture(url))

        try FileManager.default.removeItem(at: url)
        try Data("replacement".utf8).write(to: url)

        XCTAssertFalse(snapshot.matchesCurrentFile(at: url))
    }

    func test_디렉터리는_파일_스냅샷으로_인정하지_않는다() throws {
        let directory = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertNil(FileIdentitySnapshot.capture(directory))
    }
}
