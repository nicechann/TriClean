//
//  PhotoKeeperOrderTests.swift
//  TriCleanTests
//
//  유사 사진 그룹의 첫 장은 보존본(keeper)이다. 크기만 보고 고르면
//  원본 HEIC보다 큰 JPEG 내보내기본이 남고 원본이 삭제 대상이 된다.
//

import XCTest
@testable import TriClean

final class PhotoKeeperOrderTests: XCTestCase {

    private func photo(
        _ name: String,
        bytes: Int64,
        size: (Int, Int) = (4032, 3024),
        daysAgo: Double = 0
    ) -> PhotoItem {
        PhotoItem(
            url: URL(fileURLWithPath: "/photos/\(name)"),
            sizeBytes: bytes,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
            pixelWidth: size.0,
            pixelHeight: size.1
        )
    }

    private func keeper(_ items: [PhotoItem]) -> String? {
        items.sorted(by: PhotoScannerViewModel.isPreferredKeeper).first?.name
    }

    func test_해상도가_같으면_더큰_JPEG보다_원본_HEIC를_남긴다() {
        let original = photo("IMG_0001.HEIC", bytes: 2_500_000)
        let export = photo("IMG_0001.jpg", bytes: 4_800_000)

        XCTAssertEqual(keeper([export, original]), "IMG_0001.HEIC")
    }

    func test_해상도가_높은_사진을_포맷보다_우선한다() {
        let resized = photo("small.HEIC", bytes: 900_000, size: (1920, 1440))
        let full = photo("full.jpg", bytes: 3_000_000)

        XCTAssertEqual(keeper([resized, full]), "full.jpg")
    }

    func test_사본표기가_있는_파일은_남기지_않는다() {
        let copy = photo("IMG_0002 copy.jpg", bytes: 3_000_000, daysAgo: 10)
        let original = photo("IMG_0002.jpg", bytes: 3_000_000)

        XCTAssertEqual(keeper([copy, original]), "IMG_0002.jpg")
    }

    func test_나머지가_같으면_먼저만든_파일을_남긴다() {
        let older = photo("b.jpg", bytes: 3_000_000, daysAgo: 30)
        let newer = photo("a.jpg", bytes: 3_000_000, daysAgo: 1)

        XCTAssertEqual(keeper([newer, older]), "b.jpg")
    }
}
