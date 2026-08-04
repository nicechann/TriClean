//
//  DeletionIdentityRevalidationTests.swift
//  TriCleanTests
//

import XCTest
@testable import TriClean

final class DeletionIdentityRevalidationTests: XCTestCase {
    private struct Target {
        let url: URL
        let identity: FileIdentitySnapshot?
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeletionIdentityRevalidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_파일과_폴더가_그대로면_삭제후보를_유지한다() throws {
        let file = root.appendingPathComponent("file.dat")
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try Data("data".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let candidates = [
            Target(url: file, identity: FileIdentitySnapshot.captureItem(file)),
            Target(url: folder, identity: FileIdentitySnapshot.captureItem(folder))
        ]

        let result = DeletionSafety.revalidateIdentity(
            candidates,
            url: \.url,
            identity: \.identity
        )

        XCTAssertEqual(result.accepted.count, 2)
        XCTAssertEqual(result.rejectedCount, 0)
    }

    func test_같은_경로의_항목이_교체되면_삭제후보에서_제외한다() throws {
        let file = root.appendingPathComponent("replaced.dat")
        let folder = root.appendingPathComponent("replaced-folder", isDirectory: true)
        try Data("old".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let candidates = [
            Target(url: file, identity: FileIdentitySnapshot.captureItem(file)),
            Target(url: folder, identity: FileIdentitySnapshot.captureItem(folder))
        ]

        try FileManager.default.removeItem(at: file)
        try Data("new content".utf8).write(to: file)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: folder.appendingPathComponent("marker.dat"))

        let result = DeletionSafety.revalidateIdentity(
            candidates,
            url: \.url,
            identity: \.identity
        )

        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejectedCount, 2)
    }
}
