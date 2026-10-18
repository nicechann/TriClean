//
//  DuplicateStableHashTests.swift
//  TriCleanTests
//
//  해시를 읽은 내용과 삭제 직전 재검증 기준(정체성 스냅샷)이 같은 시점이어야 한다.
//  해시 도중 편집된 파일이 "바뀐 상태" 기준으로 재검증을 통과하면,
//  내용이 다른 유일한 편집본이 중복으로 삭제된다.
//

import XCTest
@testable import TriClean

final class DuplicateStableHashTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateStableHashTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String, _ content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    func test_해시중_변경이_없으면_해시시점_정체성을_돌려준다() throws {
        let file = try makeFile("stable.dat", "same content")
        let before = FileIdentitySnapshot.capture(file)

        let result = DuplicateScannerViewModel.stableContentHash(
            of: file,
            expectedSize: 12,
            hash: { _ in "digest" }
        )

        XCTAssertEqual(result?.hash, "digest")
        XCTAssertEqual(result?.identity, before)
    }

    func test_해시중_편집된_파일은_결과에서_제외한다() throws {
        let file = try makeFile("edited.dat", "original")

        let result = DuplicateScannerViewModel.stableContentHash(
            of: file,
            expectedSize: 8,
            hash: { url in
                // 해시를 읽는 사이 사용자가 같은 크기로 내용을 바꿔 저장했다.
                try? Data("modified".utf8).write(to: url)
                return "digest-of-original"
            }
        )

        XCTAssertNil(result)
    }

    func test_해시중_원자적저장으로_교체된_파일은_결과에서_제외한다() throws {
        let file = try makeFile("atomic.dat", "original")

        let result = DuplicateScannerViewModel.stableContentHash(
            of: file,
            expectedSize: 8,
            hash: { url in
                try? Data("original".utf8).write(to: url, options: .atomic)
                return "digest"
            }
        )

        XCTAssertNil(result)
    }

    func test_수집이후_크기가_달라진_파일은_해시하지_않는다() throws {
        let file = try makeFile("grown.dat", "grown since collection")
        var hashed = false

        let result = DuplicateScannerViewModel.stableContentHash(
            of: file,
            expectedSize: 4,
            hash: { _ in
                hashed = true
                return "digest"
            }
        )

        XCTAssertNil(result)
        XCTAssertFalse(hashed)
    }

    func test_해시에_실패하면_결과가_없다() throws {
        let file = try makeFile("unreadable.dat", "data")

        XCTAssertNil(DuplicateScannerViewModel.stableContentHash(
            of: file,
            expectedSize: 4,
            hash: { _ in nil }
        ))
    }
}
