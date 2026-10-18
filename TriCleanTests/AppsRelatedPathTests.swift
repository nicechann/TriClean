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

    // MARK: - 관련 파일 기본 선택 정책

    private func app(_ path: String, bundleID: String?) -> AppsInstalledApp {
        AppsInstalledApp(
            name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            bundleID: bundleID,
            url: URL(fileURLWithPath: path),
            canUninstall: true,
            isSystemApp: false,
            isAppStoreApp: false,
            modifiedDate: nil
        )
    }

    func testPreselectsWhenBundleIDIsUnique() {
        let target = app("/Applications/Foo.app", bundleID: "com.example.foo")
        let others = [target, app("/Applications/Bar.app", bundleID: "com.example.bar")]
        XCTAssertTrue(AppsViewModel.mayPreselectRelatedItems(of: target, among: others))
    }

    func testDoesNotPreselectWhenAnotherAppSharesBundleID() {
        // Xcode와 Xcode-beta처럼 같은 ID를 쓰는 앱이 남아 있으면 그 앱의 쿠키·캐시까지 지워진다.
        let beta = app("/Applications/Foo-beta.app", bundleID: "com.example.Foo")
        let stable = app("/Applications/Foo.app", bundleID: "com.example.foo")
        XCTAssertFalse(AppsViewModel.mayPreselectRelatedItems(of: beta, among: [beta, stable]))
    }

    func testDoesNotPreselectAppleBundleIDs() {
        let copy = app("/Applications/Safari Copy.app", bundleID: "com.apple.Safari")
        XCTAssertFalse(AppsViewModel.mayPreselectRelatedItems(of: copy, among: [copy]))
    }

    func testRunningCheckMatchesBundleIDCaseInsensitively() {
        XCTAssertTrue(AppsViewModel.isBundleIDRunning(
            "com.example.Foo",
            runningBundleIDs: [nil, "com.example.bar", "com.example.foo"]
        ))
        XCTAssertFalse(AppsViewModel.isBundleIDRunning(
            "com.example.foo",
            runningBundleIDs: [nil, "com.example.foo.helper"]
        ))
    }

    func testFolderInfoIDIsStableAcrossScans() {
        let url = URL(fileURLWithPath: "/Users/me/Movies/export.mov")
        let other = URL(fileURLWithPath: "/Users/me/Movies/other.mov")
        XCTAssertEqual(FolderInfo.stableID(for: url), FolderInfo.stableID(for: url))
        XCTAssertNotEqual(FolderInfo.stableID(for: url), FolderInfo.stableID(for: other))
    }
}
