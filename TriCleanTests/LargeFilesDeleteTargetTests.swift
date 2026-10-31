//
//  LargeFilesDeleteTargetTests.swift
//  TriCleanTests
//
//  대용량 파일 화면의 삭제 대상 정리 규칙.
//  - 홈의 기본 폴더·~/Library 하위 1단계·사진 보관함은 통째로 옮기지 않는다(ProtectedPaths).
//  - 상위 폴더와 그 하위 항목을 함께 고르면 상위 폴더 하나만 옮긴다. 확인창 개수도 이 기준이다.
//

import XCTest
@testable import TriClean

final class LargeFilesDeleteTargetTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LargeFilesDeleteTargetTests-\(UUID().uuidString)", isDirectory: true)
        for path in ["Documents/Project/build", "Pictures", "Library/Application Support/X", "Work/a", "Work/ab"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func folder(_ relativePath: String) -> FolderInfo {
        FolderInfo(url: home.appendingPathComponent(relativePath, isDirectory: true), sizeBytes: 100, isDirectory: true)
    }

    private func file(_ relativePath: String, bytes: Int64 = 10) -> FolderInfo {
        FolderInfo(url: home.appendingPathComponent(relativePath), sizeBytes: bytes, isDirectory: false)
    }

    private func names(_ items: [FolderInfo]) -> [String] {
        items.map { $0.url.path.replacingOccurrences(of: home.path + "/", with: "") }
    }

    // MARK: - ProtectedPaths

    func test_홈의_기본폴더와_라이브러리_하위1단계는_보호한다() {
        for path in ["Documents", "Pictures", "Desktop", "Library", "Library/Application Support", "Library/Containers"] {
            XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent(path), home: home), path)
        }
        XCTAssertTrue(ProtectedPaths.isProtected(home, home: home))
    }

    func test_사진보관함_패키지는_어디에있든_보호한다() {
        let library = home.appendingPathComponent("Work/Old Photos Library.photoslibrary")
        XCTAssertTrue(ProtectedPaths.isProtected(library, home: home))
        XCTAssertTrue(ProtectedPaths.isProtected(library, home: home, resolvingSymlinks: false))
    }

    func test_사용자가_만든_폴더와_더깊은_항목은_보호하지않는다() {
        for path in ["Work", "Documents/Project", "Library/Application Support/X", "Pictures/2019"] {
            XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent(path), home: home), path)
        }
    }

    func test_동기화서비스_루트와_이름뿐인_보관함도_보호한다() {
        for path in [
            "Library/Mobile Documents/com~apple~CloudDocs",
            "Library/CloudStorage/Dropbox",
            "Pictures/Photo Booth Library"
        ] {
            XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent(path), home: home), path)
        }
        // 동기화 폴더 안의 사용자 폴더는 일반 폴더처럼 다룬다.
        XCTAssertFalse(ProtectedPaths.isProtected(
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Projects"), home: home
        ))
    }

    func test_보관함을_담은_폴더는_스캔표시로_보호한다() {
        // ~/Music/Music처럼 경로만으로는 알 수 없는 폴더. 스캔이 남긴 표시로 막는다.
        let musicFolder = FolderInfo(
            url: home.appendingPathComponent("Work/Music", isDirectory: true),
            sizeBytes: 100,
            isDirectory: true,
            containsManagedLibrary: true
        )
        let prepared = LargeFilesViewModel.prepareDeleteTargets([musicFolder, folder("Work/a")], home: home)
        XCTAssertEqual(names(prepared.targets), ["Work/a"])
        XCTAssertEqual(prepared.protectedCount, 1)
    }

    // MARK: - 정규화

    func test_상위폴더와_하위항목을_함께고르면_상위폴더만_남긴다() {
        let targets = LargeFilesViewModel.normalizedDeleteTargets([
            file("Documents/Project/build/app.zip"),
            folder("Documents/Project"),
            folder("Documents/Project/build")
        ])
        XCTAssertEqual(names(targets), ["Documents/Project"])
    }

    func test_이름이_접두어만_같은_형제폴더는_하위로_보지않는다() {
        let targets = LargeFilesViewModel.normalizedDeleteTargets([folder("Work/a"), folder("Work/ab")])
        XCTAssertEqual(Set(names(targets)), ["Work/a", "Work/ab"])
    }

    func test_같은항목이_두번_들어와도_한번만_남긴다() {
        let targets = LargeFilesViewModel.normalizedDeleteTargets([folder("Work/a"), folder("Work/a")])
        XCTAssertEqual(names(targets), ["Work/a"])
    }

    func test_확인창_대상에서_보호위치를_빼고_개수를_센다() {
        let prepared = LargeFilesViewModel.prepareDeleteTargets(
            [folder("Pictures"), folder("Documents"), folder("Work"), file("Work/a/big.mov"), folder("Library/Application Support")],
            home: home
        )
        XCTAssertEqual(names(prepared.targets), ["Work"])
        XCTAssertEqual(prepared.protectedCount, 3)
    }

    func test_보호폴더와_그안의_파일을_함께고르면_파일은_대상에_남는다() {
        // 정규화를 먼저 하면 파일이 보호 폴더에 흡수된 뒤 폴더째 빠져 조용히 사라졌다.
        let prepared = LargeFilesViewModel.prepareDeleteTargets(
            [folder("Documents"), file("Documents/Project/build/app.zip", bytes: 500), folder("Pictures")],
            home: home
        )
        XCTAssertEqual(names(prepared.targets), ["Documents/Project/build/app.zip"])
        XCTAssertEqual(prepared.protectedCount, 2)
    }

    func test_정규화는_항목이_많아도_빠르다() {
        // 예전 구현은 비교마다 realpath를 다시 호출하고 O(n²)로 포함 여부를 검사했다.
        let items = (0..<3_000).map { file("Work/a/file-\($0).bin") } + [folder("Work/a")]
        measure(metrics: [XCTClockMetric()]) {
            XCTAssertEqual(LargeFilesViewModel.normalizedDeleteTargets(items).count, 1)
        }
    }
}
