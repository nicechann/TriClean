//
//  DuplicateRecommendationTests.swift
//  TriCleanTests
//
//  "어떤 사본을 남길 것인가"를 잘못 고르면 사용자가 원본을 잃는다.
//

import XCTest
@testable import TriClean

final class DuplicateRecommendationTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/root")

    private func file(_ path: String, daysAgo: Int? = nil) -> DuplicateFile {
        DuplicateFile(
            url: URL(fileURLWithPath: path),
            modificationDate: daysAgo.map { Date().addingTimeInterval(-Double($0) * 86_400) },
            isKeep: false
        )
    }

    func test_얕은_경로의_파일을_보존한다() {
        let files = [
            file("/tmp/root/sub/deep/photo.jpg"),
            file("/tmp/root/photo.jpg")
        ]
        XCTAssertEqual(
            DuplicateScannerViewModel.recommendedKeepIndex(for: files, rootURL: root), 1
        )
    }

    func test_사본_표기가_있는_파일은_보존하지_않는다() {
        let files = [
            file("/tmp/root/report 사본.pdf"),
            file("/tmp/root/report.pdf")
        ]
        XCTAssertEqual(
            DuplicateScannerViewModel.recommendedKeepIndex(for: files, rootURL: root), 1
        )
    }

    func test_다국어_사본_표기도_인식한다() {
        for marker in ["copy", "Kopie", "copia", "copie", "コピー", "복사본"] {
            let files = [
                file("/tmp/root/note \(marker).txt"),
                file("/tmp/root/note.txt")
            ]
            XCTAssertEqual(
                DuplicateScannerViewModel.recommendedKeepIndex(for: files, rootURL: root), 1,
                "마커 '\(marker)'가 있는 파일이 보존 대상으로 선택되었습니다"
            )
        }
    }

    func test_다운로드_폴더보다_문서_폴더를_선호한다() {
        let files = [
            file("/tmp/root/Downloads/a.pdf"),
            file("/tmp/root/Documents/a.pdf")
        ]
        XCTAssertEqual(
            DuplicateScannerViewModel.recommendedKeepIndex(for: files, rootURL: root), 1
        )
    }

    func test_보존_대상은_항상_유효한_인덱스다() {
        let files = [file("/tmp/root/a.txt"), file("/tmp/root/b.txt"), file("/tmp/root/c.txt")]
        let index = DuplicateScannerViewModel.recommendedKeepIndex(for: files, rootURL: root)
        XCTAssertTrue(files.indices.contains(index))
    }

    func test_빈_배열에서도_크래시하지_않는다() {
        XCTAssertEqual(
            DuplicateScannerViewModel.recommendedKeepIndex(for: [], rootURL: root), 0
        )
    }

    func test_동일_입력에_대해_결과가_결정적이다() {
        let files = [
            file("/tmp/root/a.txt", daysAgo: 10),
            file("/tmp/root/b.txt", daysAgo: 10)
        ]
        let first = DuplicateScannerViewModel.recommendedKeepIndex(for: files, rootURL: root)
        let second = DuplicateScannerViewModel.recommendedKeepIndex(for: files, rootURL: root)
        XCTAssertEqual(first, second)
    }
}
