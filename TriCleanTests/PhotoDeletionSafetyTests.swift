//
//  PhotoDeletionSafetyTests.swift
//  TriCleanTests
//
//  유사 사진 삭제 직전에 보존본이 사라진 경우 그룹 전체 삭제를 막는지 검증합니다.
//

import XCTest
@testable import TriClean

final class PhotoDeletionSafetyTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDeletionSafetyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func item(_ name: String, create: Bool) throws -> PhotoItem {
        let url = root.appendingPathComponent(name)
        if create {
            try Data("image".utf8).write(to: url)
        }
        return PhotoItem(
            url: url,
            sizeBytes: 5,
            modificationDate: nil,
            pixelWidth: 100,
            pixelHeight: 100
        )
    }

    func test_보존본이_사라지면_선택한_그룹을_삭제하지_않는다() throws {
        let missingKeeper = try item("keeper.jpg", create: false)
        let selectedCopy = try item("copy.jpg", create: true)
        let group = PhotoGroup(id: "group", items: [missingKeeper, selectedCopy])

        let result = PhotoScannerViewModel.preparePhotoDeletion(
            selected: [selectedCopy],
            similarGroups: [group],
            scope: root
        )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertEqual(result.excludedItemCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selectedCopy.url.path))
    }

    func test_보존본이_존재하면_선택한_사본만_허용한다() throws {
        let keeper = try item("keeper.jpg", create: true)
        let selectedCopy = try item("copy.jpg", create: true)
        let group = PhotoGroup(id: "group", items: [keeper, selectedCopy])

        let result = PhotoScannerViewModel.preparePhotoDeletion(
            selected: [selectedCopy],
            similarGroups: [group],
            scope: root
        )

        XCTAssertEqual(result.targets.map(\.id), [selectedCopy.id])
        XCTAssertEqual(result.excludedItemCount, 0)
    }
    func test_보존본이_같은_경로의_다른_파일로_교체되면_삭제하지_않는다() throws {
        let keeper = try item("keeper-replaced.jpg", create: true)
        let selectedCopy = try item("copy-replaced.jpg", create: true)
        let group = PhotoGroup(id: "group-replaced", items: [keeper, selectedCopy])

        try FileManager.default.removeItem(at: keeper.url)
        try Data("different image".utf8).write(to: keeper.url)

        let result = PhotoScannerViewModel.preparePhotoDeletion(
            selected: [selectedCopy],
            similarGroups: [group],
            scope: root
        )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertEqual(result.excludedItemCount, 1)
    }

    func test_삭제대상이_같은_경로의_다른_파일로_교체되면_제외한다() throws {
        let selected = try item("selected-replaced.jpg", create: true)

        try FileManager.default.removeItem(at: selected.url)
        try Data("new file".utf8).write(to: selected.url)

        let result = PhotoScannerViewModel.preparePhotoDeletion(
            selected: [selected],
            similarGroups: [],
            scope: root
        )

        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertEqual(result.excludedItemCount, 1)
    }

}
