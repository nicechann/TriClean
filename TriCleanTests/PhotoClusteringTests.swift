//
//  PhotoClusteringTests.swift
//  TriCleanTests
//
//  유사 사진 그룹은 "그룹 전체 선택 후 삭제" UI와 직결되므로,
//  무관한 사진이 한 그룹에 섞이는 오탐을 반드시 막아야 한다.
//

import XCTest
@testable import TriClean

final class PhotoClusteringTests: XCTestCase {

    private let threshold = 6

    private func cluster(_ pairs: [(String, UInt64)]) -> [Set<String>] {
        PhotoScannerViewModel.clusterByHash(pairs, threshold: threshold).map(Set.init)
    }

    func test_동일한_해시는_한_그룹으로_묶인다() {
        let groups = cluster([("a", 0x00FF_00FF_00FF_00FF), ("b", 0x00FF_00FF_00FF_00FF)])
        XCTAssertEqual(groups, [["a", "b"]])
    }

    func test_충분히_다른_해시는_묶이지_않는다() {
        let groups = cluster([("a", 0x0000_0000_0000_0000), ("b", 0xFFFF_FFFF_FFFF_FFFF)])
        XCTAssertTrue(groups.isEmpty)
    }

    func test_단독_항목은_그룹에_포함되지_않는다() {
        let groups = cluster([("a", 0x0), ("b", 0x3F), ("lonely", 0xFFFF_FFFF_FFFF_FFFF)])
        XCTAssertEqual(groups, [["a", "b"]])
    }

    /// 비추이성 회귀 테스트.
    /// a~b = 6, b~c = 6, a~c = 12. b가 그룹 대표가 되는 입력 순서에서
    /// 기존 구현은 a와 c를 같은 그룹에 넣었다.
    func test_대표만_비교하던_비추이_묶음을_방지한다() {
        let a: UInt64 = 0x0000_0000_0000_0000
        let b: UInt64 = 0x0000_0000_0000_003F   // a와 6비트 차이
        let c: UInt64 = 0x0000_0000_0000_0FFF   // b와 6비트, a와는 12비트 차이

        XCTAssertEqual((a ^ b).nonzeroBitCount, 6, "테스트 픽스처 전제 확인")
        XCTAssertEqual((b ^ c).nonzeroBitCount, 6, "테스트 픽스처 전제 확인")
        XCTAssertEqual((a ^ c).nonzeroBitCount, 12, "테스트 픽스처 전제 확인")

        let groups = cluster([("b", b), ("a", a), ("c", c)])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first, ["a", "b"])
        XCTAssertFalse(
            groups.contains { $0.contains("a") && $0.contains("c") },
            "임계값을 넘는 두 사진이 같은 그룹에 묶였습니다"
        )
    }

    func test_입력_순서가_바뀌어도_같은_그룹을_만든다() {
        let items: [(String, UInt64)] = [
            ("a1", 0x0000_0000_0000_0000),
            ("a2", 0x0000_0000_0000_0001),
            ("b1", 0xFFFF_FFFF_FFFF_FFFF),
            ("b2", 0xFFFF_FFFF_FFFF_FFFE)
        ]
        let forward = Set(cluster(items))
        let backward = Set(cluster(items.reversed()))

        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward, [["a1", "a2"], ["b1", "b2"]])
    }

    func test_빈_입력에서_크래시하지_않는다() {
        XCTAssertTrue(cluster([]).isEmpty)
    }
}
