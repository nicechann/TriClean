//
//  AppsRelatedPathTests.swift
//  TriCleanTests
//
//  앱 잔여 파일 경로는 앱 Info.plist의 번들 ID·이름으로 조합된다.
//  조작된 값이 무관한 Library 폴더를 삭제 후보로 만들지 않는지 검증한다.
//

import XCTest
@testable import TriClean

@MainActor
final class AppsRelatedPathTests: XCTestCase {

    func testRejectsTraversalAndSeparators() {
        for name in ["", ".", "..", "../Keychains", "a/b", "com:evil", "a\0b"] {
            XCTAssertFalse(AppsViewModel.isSafePathComponent(name), "should reject \(name.debugDescription)")
        }
    }

    func testAcceptsOrdinaryBundleIDsAndNames() {
        for name in ["com.example.App", "com.example.app-helper", "My App", "Notes_2"] {
            XCTAssertTrue(AppsViewModel.isSafePathComponent(name), "should accept \(name)")
        }
    }

    func testDirectChildCheck() {
        let caches = URL(fileURLWithPath: "/Users/me/Library/Caches", isDirectory: true)
        XCTAssertTrue(AppsViewModel.isDirectChild(caches.appendingPathComponent("com.example.App"), of: caches))
        XCTAssertFalse(AppsViewModel.isDirectChild(caches.appendingPathComponent(".."), of: caches))
        XCTAssertFalse(AppsViewModel.isDirectChild(caches.appendingPathComponent("a/b"), of: caches))
    }

    func testFolderInfoIDIsStableAcrossScans() {
        let url = URL(fileURLWithPath: "/Users/me/Movies/export.mov")
        let other = URL(fileURLWithPath: "/Users/me/Movies/other.mov")
        XCTAssertEqual(FolderInfo.stableID(for: url), FolderInfo.stableID(for: url))
        XCTAssertNotEqual(FolderInfo.stableID(for: url), FolderInfo.stableID(for: other))
    }
}
