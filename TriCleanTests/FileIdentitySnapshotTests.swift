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

    func test_디렉터리_스냅샷은_같은_디렉터리와_일치한다() throws {
        let directory = root.appendingPathComponent("same-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let snapshot = try XCTUnwrap(FileIdentitySnapshot.captureItem(directory))

        XCTAssertEqual(snapshot.itemType, .directory)
        XCTAssertTrue(snapshot.matchesCurrentItem(at: directory))
    }

    func test_동적디렉터리는_내용변경을_허용해도_같은_inode를_유지한다() throws {
        let directory = root.appendingPathComponent("dynamic-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = try XCTUnwrap(FileIdentitySnapshot.captureItem(directory))

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
            ofItemAtPath: directory.path
        )

        XCTAssertFalse(snapshot.matchesCurrentItem(at: directory))
        XCTAssertTrue(
            snapshot.matchesCurrentItem(
                at: directory,
                allowDirectoryContentChanges: true
            )
        )
    }

    func test_같은_경로의_디렉터리를_교체하면_일치하지_않는다() throws {
        let directory = root.appendingPathComponent("replaced-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = try XCTUnwrap(FileIdentitySnapshot.captureItem(directory))

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: directory.appendingPathComponent("marker.dat"))

        XCTAssertFalse(snapshot.matchesCurrentItem(at: directory))
        XCTAssertFalse(
            snapshot.matchesCurrentItem(
                at: directory,
                allowDirectoryContentChanges: true
            )
        )
    }

    func test_심볼릭_링크는_항목_스냅샷으로_인정하지_않는다() throws {
        let file = root.appendingPathComponent("target.dat")
        let link = root.appendingPathComponent("link.dat")
        try Data("target".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        XCTAssertNil(FileIdentitySnapshot.captureItem(link))
    }

}
