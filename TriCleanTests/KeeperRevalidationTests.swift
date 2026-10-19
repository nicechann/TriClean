//
//  KeeperRevalidationTests.swift
//  TriCleanTests
//
//  중복 파일·유사 사진은 사본을 하나씩 휴지통으로 옮기는 사이 보존본이 외부에서
//  지워지거나 바뀔 수 있다. 보존본이 사라진 뒤의 사본은 옮기지 않아야 원본까지 잃지 않는다.
//

import XCTest
@testable import TriClean

final class DuplicateKeeperRevalidationTests: XCTestCase {

    private var root: URL!
    private var fakeTrash: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateKeeperRevalidationTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("scan", isDirectory: true)
        fakeTrash = base.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("same content".utf8).write(to: url)
        return url
    }

    private func target(_ url: URL) -> DuplicateScannerViewModel.DeleteTarget {
        DuplicateScannerViewModel.DeleteTarget(
            fileID: UUID(),
            url: url,
            perFileSize: 12,
            fileIdentity: FileIdentitySnapshot.capture(url)
        )
    }

    func test_삭제도중_보존본이_외부에서_지워지면_남은사본을_옮기지않는다() async throws {
        let keeper = try makeFile("original.jpg")
        let first = try makeFile("original copy.jpg")
        let second = try makeFile("original copy 2.jpg")
        let snapshot = DuplicateScannerViewModel.DeleteGroupSnapshot(
            keeper: DuplicateScannerViewModel.KeeperSnapshot(url: keeper, fileIdentity: FileIdentitySnapshot.capture(keeper)),
            targets: [target(first), target(second)]
        )

        let trash: URL = fakeTrash
        let mover = TrashService.Mover(
            trashItem: { url in
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
                // 첫 사본을 옮기는 사이 동기화 등으로 보존본이 지워졌다.
                if url.lastPathComponent == "original copy.jpg" {
                    try FileManager.default.removeItem(at: keeper)
                }
            },
            recycle: { _ in nil }
        )

        let outcome = await DuplicateScannerViewModel.prepareAndPerformDeletion(
            snapshots: [snapshot],
            folder: root,
            mover: mover
        )

        XCTAssertEqual(outcome.deletedCount, 1)
        XCTAssertEqual(outcome.excludedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func test_보존본이_그대로면_모든사본을_옮긴다() async throws {
        let keeper = try makeFile("keep.jpg")
        let copies = [try makeFile("a.jpg"), try makeFile("b.jpg")]
        let snapshot = DuplicateScannerViewModel.DeleteGroupSnapshot(
            keeper: DuplicateScannerViewModel.KeeperSnapshot(url: keeper, fileIdentity: FileIdentitySnapshot.capture(keeper)),
            targets: copies.map(target)
        )
        let trash: URL = fakeTrash
        let mover = TrashService.Mover(
            trashItem: { try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent(UUID().uuidString)) },
            recycle: { _ in nil }
        )

        let outcome = await DuplicateScannerViewModel.prepareAndPerformDeletion(
            snapshots: [snapshot],
            folder: root,
            mover: mover
        )

        XCTAssertEqual(outcome.deletedCount, 2)
        XCTAssertEqual(outcome.excludedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
    }
}

@MainActor
final class PhotoKeeperRevalidationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoKeeperRevalidationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func photo(_ name: String, size: (Int, Int) = (4032, 3024)) throws -> PhotoItem {
        let url = root.appendingPathComponent(name)
        try Data("image".utf8).write(to: url)
        return PhotoItem(url: url, sizeBytes: 5, modificationDate: nil, pixelWidth: size.0, pixelHeight: size.1)
    }

    func test_이동직전_보존본이_사라지면_사본을_건너뛴다() throws {
        let keeper = try photo("keeper.heic")
        let copy = try photo("copy.jpg")
        let group = PhotoGroup(id: keeper.id, items: [keeper, copy])

        let preparation = PhotoScannerViewModel.preparePhotoDeletion(selected: [copy], similarGroups: [group], scope: root)
        XCTAssertEqual(preparation.targets.map(\.id), [copy.id])
        XCTAssertEqual(PhotoScannerViewModel.survivorPreflight(for: copy, preparation: preparation), .proceed)

        try FileManager.default.removeItem(at: keeper.url)

        XCTAssertEqual(PhotoScannerViewModel.survivorPreflight(for: copy, preparation: preparation), .skip)
    }

    func test_그룹이_생기면_미리_선택해둔_보존본의_선택을_해제한다() throws {
        let vm = PhotoScannerViewModel()
        let keeper = try photo("IMG_0001.HEIC")
        let export = try photo("IMG_0001.jpg")
        vm.items = [export, keeper]
        // 전체 탭에서 두 장을 모두 선택해 둔 상태
        vm.selectedIDs = [keeper.id, export.id]

        vm.applySimilarGroups([[export.id, keeper.id]])

        XCTAssertEqual(vm.similarGroups.first?.items.first?.id, keeper.id)
        XCTAssertEqual(vm.selectedIDs, [export.id])
    }
}
