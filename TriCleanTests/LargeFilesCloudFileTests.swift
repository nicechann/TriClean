//
//  LargeFilesCloudFileTests.swift
//  TriCleanTests
//
//  대용량 파일 화면이 "지우면 확보되는 로컬 용량"만 보여 주는지.
//  - 클라우드 전용 파일(iCloud 저장 공간 최적화, Dropbox·OneDrive File Provider)은 후보에서 뺀다.
//  - 할당 크기를 알 수 없는 파일은 논리 크기로 대신 표시하지 않는다.
//  - 클라우드 전용 파일이 든 폴더는 통째로 옮기지 않는다.
//

import XCTest
@testable import TriClean

final class LargeFilesCloudFileTests: XCTestCase {

    private typealias Snapshot = CloudFileStatus.Snapshot
    private let fiveGB = 5_000_000_000
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LargeFilesCloudFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - 확보 가능 용량

    func test_로컬_파일은_할당크기를_확보용량으로_쓴다() {
        let local = Snapshot(logicalSize: 5_000, allocatedSize: 8_192)
        XCTAssertFalse(CloudFileStatus.isDataless(local))
        XCTAssertEqual(LargeFilesViewModel.reclaimableBytes(from: local), 8_192)

        let downloaded = Snapshot(downloadingStatus: .current, logicalSize: fiveGB, allocatedSize: fiveGB)
        XCTAssertEqual(LargeFilesViewModel.reclaimableBytes(from: downloaded), Int64(fiveGB))
    }

    func test_iCloud_전용_파일은_후보에서_뺀다() {
        let cloudOnly = Snapshot(downloadingStatus: .notDownloaded, logicalSize: fiveGB, allocatedSize: 0)
        XCTAssertTrue(CloudFileStatus.isDataless(cloudOnly))
        XCTAssertNil(LargeFilesViewModel.reclaimableBytes(from: cloudOnly))

        // 할당 크기를 읽지 못해도 iCloud가 "내려받지 않음"이라고 하면 클라우드 전용이다.
        let unknownAllocation = Snapshot(downloadingStatus: .notDownloaded, logicalSize: fiveGB, allocatedSize: nil)
        XCTAssertNil(LargeFilesViewModel.reclaimableBytes(from: unknownAllocation))
    }

    func test_Dropbox_OneDrive_자리표시자는_후보에서_뺀다() {
        // 서드파티 File Provider는 iCloud 상태 키가 비어 있고, 논리 크기만 있고 할당 블록은 0이다.
        let placeholder = Snapshot(downloadingStatus: nil, volumeIsLocal: true, logicalSize: fiveGB, allocatedSize: 0)
        XCTAssertTrue(CloudFileStatus.isDataless(placeholder))
        XCTAssertNil(LargeFilesViewModel.reclaimableBytes(from: placeholder))
    }

    func test_할당크기를_모르면_논리크기로_대신하지_않는다() {
        let unknown = Snapshot(downloadingStatus: nil, volumeIsLocal: true, logicalSize: fiveGB, allocatedSize: nil)
        XCTAssertFalse(CloudFileStatus.isDataless(unknown))
        XCTAssertNil(LargeFilesViewModel.reclaimableBytes(from: unknown))
    }

    func test_네트워크_볼륨의_0블록_파일은_확보용량을_부풀리지_않는다() {
        // SMB/NFS는 할당 정보를 0으로 채운다. 클라우드 전용으로 단정하지 않되, 논리 크기(5GB)도 쓰지 않는다.
        let network = Snapshot(downloadingStatus: nil, volumeIsLocal: false, logicalSize: fiveGB, allocatedSize: 0)
        XCTAssertFalse(CloudFileStatus.isDataless(network))
        XCTAssertEqual(LargeFilesViewModel.reclaimableBytes(from: network), 0)
    }

    // MARK: - 폴더 잠금

    func test_클라우드_전용_파일이_든_폴더는_통째로_옮기지_않는다() {
        let cloudFolder = FolderInfo(url: home.appendingPathComponent("Work"), sizeBytes: 100,
                                     isDirectory: true, containsCloudOnlyItems: true)
        XCTAssertEqual(LargeFilesViewModel.deleteLock(for: cloudFolder, home: home), .cloudOnly)
        XCTAssertEqual(LargeFilesViewModel.deletionPreflight(cloudFolder), .skip)

        // 보호 위치가 우선, 다음이 클라우드 전용, 마지막이 불완전 스캔이다.
        let protectedFolder = FolderInfo(url: home.appendingPathComponent("Documents"), sizeBytes: 100,
                                         isDirectory: true, containsCloudOnlyItems: true)
        XCTAssertEqual(LargeFilesViewModel.deleteLock(for: protectedFolder, home: home), .protected)
        let cloudAndIncomplete = FolderInfo(url: home.appendingPathComponent("Other"), sizeBytes: 100,
                                            isDirectory: true, isScanComplete: false, containsCloudOnlyItems: true)
        XCTAssertEqual(LargeFilesViewModel.deleteLock(for: cloudAndIncomplete, home: home), .cloudOnly)

        let localFile = FolderInfo(url: home.appendingPathComponent("Work/movie.mov"), sizeBytes: 100,
                                   isDirectory: false, depth: 1, parentURL: home.appendingPathComponent("Work"))
        let prepared = LargeFilesViewModel.prepareDeleteTargets([cloudFolder, protectedFolder, localFile], home: home)
        // 폴더는 빠지지만 그 안의 로컬 파일은 따로 옮길 수 있다.
        XCTAssertEqual(prepared.targets.map(\.url), [localFile.url])
        XCTAssertEqual(prepared.cloudOnlyCount, 1)
        XCTAssertEqual(prepared.protectedCount, 1)
        XCTAssertEqual(prepared.incompleteCount, 0)
    }

    // MARK: - 실제 파일

    func test_로컬_파일은_스캔과_삭제직전_확인을_통과한다() async throws {
        let work = home.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let rootFile = home.appendingPathComponent("root.bin")
        let childFile = work.appendingPathComponent("child.bin")
        try Data(repeating: 1, count: 2 * 1024 * 1024).write(to: rootFile)
        try Data(repeating: 2, count: 2 * 1024 * 1024).write(to: childFile)

        var results: [FolderInfo] = []
        for await batch in LargeFilesViewModel.scanStructuredItemsBatches(
            of: home, minSizeMB: 1, ignoredFolderURLs: [], batchSize: 50
        ) { results.append(contentsOf: batch) }

        let allocated = try XCTUnwrap(
            rootFile.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
        )
        let root = try XCTUnwrap(results.first { $0.url.lastPathComponent == "root.bin" })
        XCTAssertEqual(root.sizeBytes, Int64(allocated))
        let folder = try XCTUnwrap(results.first { $0.url.lastPathComponent == "Work" })
        XCTAssertFalse(folder.containsCloudOnlyItems)
        XCTAssertTrue(results.contains { $0.url.lastPathComponent == "child.bin" })

        XCTAssertEqual(LargeFilesViewModel.deletionPreflight(root), .proceed)
        XCTAssertEqual(LargeFilesViewModel.deletionPreflight(folder), .proceed)
    }

    func test_스캔후_사라진_파일은_삭제직전_확인에서_뺀다() throws {
        let file = home.appendingPathComponent("gone.bin")
        try Data(repeating: 1, count: 4096).write(to: file)
        let item = FolderInfo(url: file, sizeBytes: 4096, isDirectory: false)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(LargeFilesViewModel.deletionPreflight(item), .skip)
    }
}
