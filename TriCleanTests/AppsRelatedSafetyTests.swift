//
//  AppsRelatedSafetyTests.swift
//  TriCleanTests
//
//  앱 잔여 파일의 후보 선정·삭제·스캔 상태를 실제 파일 시스템(임시 Library)으로 검증한다.
//  - 중간 경로가 심볼릭 링크인 항목은 스캔·삭제 모두에서 제외한다(정크 정리와 같은 정책).
//  - 삭제 도중 대상 앱이 실행되면 남은 항목을 옮기지 않는다.
//  - Details를 닫거나 다른 앱을 고르면 이전 스캔 결과가 화면에 반영되지 않는다.
//

import XCTest
@testable import TriClean

@MainActor
final class AppsRelatedSafetyTests: XCTestCase {

    private let bundleID = "com.example.foo"
    private var library: URL!
    private var fakeTrash: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppsRelatedSafetyTests-\(UUID().uuidString)", isDirectory: true)
        library = base.appendingPathComponent("Library", isDirectory: true)
        fakeTrash = base.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: library.deletingLastPathComponent())
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ relativePath: String, bytes: Int = 4096) throws -> URL {
        let url = library.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func link(_ relativePath: String, to destinationRelativePath: String) throws {
        let url = library.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: library.appendingPathComponent(destinationRelativePath)
        )
    }

    private func path(_ relativePath: String) -> String {
        library.appendingPathComponent(relativePath).standardizedFileURL.path
    }

    private func scan() -> [AppsRelatedItem] {
        AppsViewModel.findRelatedItems(in: library, appName: "Foo", bundleID: bundleID)
    }

    private var mover: TrashService.Mover {
        let trash: URL = fakeTrash
        return TrashService.Mover(
            trashItem: { url in
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
            },
            recycle: { url in
                XCTFail("recycle fallback should not run for \(url.lastPathComponent)")
                return nil
            }
        )
    }

    // MARK: - 스캔: 숨김 항목 크기·심볼릭 링크

    func test_잔여폴더_크기에_숨김항목을_포함한다() throws {
        try write("Caches/\(bundleID)/data.bin", bytes: 4096)
        try write("Caches/\(bundleID)/.git/objects/blob", bytes: 256 * 1024)

        let caches = try XCTUnwrap(scan().first { $0.url.standardizedFileURL.path == path("Caches/\(bundleID)") })
        XCTAssertGreaterThanOrEqual(caches.sizeBytes, 256 * 1024 + 4096)
    }

    func test_스캔은_하위폴더나_항목이_링크인_경로를_후보에서_제외한다() throws {
        try write("Caches/\(bundleID)/data.bin")
        // WebKit 폴더 자체가 다른 앱의 데이터 폴더를 가리키는 링크
        try write("Application Support/Other/\(bundleID)/IndexedDB.sqlite")
        try link("WebKit", to: "Application Support/Other")
        // HTTPStorages/<id> 항목 자체가 링크
        try write("Application Support/Cookies/cookies.binarycookies")
        try link("HTTPStorages/\(bundleID)", to: "Application Support/Cookies")
        // 이름 기반 경로도 같은 정책
        try write("Application Support/Shared/vault.db")
        try link("Caches/Foo", to: "Application Support/Shared")

        let paths = Set(scan().map { $0.url.standardizedFileURL.path })

        XCTAssertTrue(paths.contains(path("Caches/\(bundleID)")))
        XCTAssertFalse(paths.contains(path("WebKit/\(bundleID)")))
        XCTAssertFalse(paths.contains(path("HTTPStorages/\(bundleID)")))
        XCTAssertFalse(paths.contains(path("Caches/Foo")))
    }

    func test_스캔결과는_설치여부와_무관하게_기본선택하지않는다() throws {
        try write("Caches/\(bundleID)/data.bin")
        try write("Preferences/\(bundleID).plist")

        let items = scan()
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { !$0.selected })
        // 앱이 제거된 뒤에만 기본 선택할 수 있는 저위험 항목 표시는 남긴다.
        let caches = items.first { $0.url.lastPathComponent == bundleID }
        let prefs = items.first { $0.url.lastPathComponent == "\(bundleID).plist" }
        XCTAssertEqual(caches?.isDefaultSelectable, true)
        XCTAssertEqual(prefs?.isDefaultSelectable, false)
    }

    // MARK: - 삭제: 경로 교체·실행 상태

    func test_스캔후_중간경로가_링크로_바뀌면_삭제하지않는다() async throws {
        try write("Caches/\(bundleID)/data.bin")
        let target = try XCTUnwrap(scan().first { $0.url.lastPathComponent == bundleID })

        // Caches를 옮기고 그 자리에 링크를 둔다. 같은 경로로 같은 inode에 도달하므로
        // 정체성 검사만으로는 통과한다 — 링크 검사가 막아야 한다.
        let realCaches = library.appendingPathComponent("RealCaches")
        try FileManager.default.moveItem(at: library.appendingPathComponent("Caches"), to: realCaches)
        try link("Caches", to: "RealCaches")
        XCTAssertEqual(
            target.fileIdentity?.matchesCurrentItem(at: target.url, allowDirectoryContentChanges: true),
            true
        )

        let outcome = await AppsViewModel.performRelatedRemoval(
            targets: [target],
            libraryRoot: library,
            bundleID: bundleID,
            isAppRunning: { _ in false },
            mover: mover
        )

        XCTAssertEqual(outcome.succeededCount, 0)
        XCTAssertEqual(outcome.excludedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: realCaches.appendingPathComponent(bundleID).path))
    }

    func test_삭제도중_앱이_실행되면_남은항목을_옮기지않는다() async throws {
        try write("Caches/\(bundleID)/a.bin")
        try write("HTTPStorages/\(bundleID)/b.bin")
        try write("WebKit/\(bundleID)/c.bin")
        let targets = scan().filter { $0.url.lastPathComponent == bundleID }
        XCTAssertEqual(targets.count, 3)

        var checks = 0
        let outcome = await AppsViewModel.performRelatedRemoval(
            targets: targets,
            libraryRoot: library,
            bundleID: bundleID,
            isAppRunning: { _ in
                checks += 1
                return checks > 1   // 첫 항목을 옮긴 뒤 앱이 실행됐다.
            },
            mover: mover
        )

        XCTAssertEqual(outcome.succeededCount, 1)
        XCTAssertEqual(outcome.interruptedCount, 2)
        XCTAssertEqual(outcome.failedCount + outcome.excludedCount, 0)
        for item in outcome.interrupted {
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path), item.url.path)
        }
    }

    func test_시작시점에_앱이_실행중이면_아무것도_옮기지않는다() async throws {
        try write("Caches/\(bundleID)/a.bin")
        let targets = scan()

        let outcome = await AppsViewModel.performRelatedRemoval(
            targets: targets,
            libraryRoot: library,
            bundleID: bundleID,
            isAppRunning: { _ in true },
            mover: mover
        )

        XCTAssertEqual(outcome.succeededCount, 0)
        XCTAssertEqual(outcome.interruptedCount, targets.count)
    }

    func test_중단결과_문구는_옮긴수와_중단사유를_함께알린다() {
        let runningNote = "apps.status.related_app_running".localized(with: "Foo")

        let partial = AppsViewModel.relatedRemovalMessage(succeeded: 1, failed: 0, skipped: 0, interrupted: 2, appName: "Foo")
        XCTAssertTrue(partial.hasPrefix("apps.status.related_success".localized(with: 1)))
        XCTAssertTrue(partial.hasSuffix(runningNote))

        let none = AppsViewModel.relatedRemovalMessage(succeeded: 0, failed: 0, skipped: 0, interrupted: 3, appName: "Foo")
        XCTAssertEqual(none, runningNote)

        let normal = AppsViewModel.relatedRemovalMessage(succeeded: 2, failed: 0, skipped: 0, interrupted: 0, appName: "Foo")
        XCTAssertEqual(normal, "apps.status.related_success".localized(with: 2))
    }

    // MARK: - 중복 실행 방지

    func test_제거가_진행중이면_두번째_실행을_막는다() {
        // 창이 여러 개면 확인창도 창마다 뜬다. 진행 중에 들어온 실행은 아무것도 하지 않아야 한다.
        let vm = AppsViewModel()
        vm.isRemoving = true
        vm.lastStatusMessage = "marker"

        vm.removeSelectedRelatedItems()
        XCTAssertEqual(vm.lastStatusMessage, "marker")

        var completed = false
        var alert: AppsActiveAlert? = .removeRelatedFiles
        vm.uninstallSelectedInstalledApps { result in
            alert = result
            completed = true
        }
        XCTAssertTrue(completed)
        XCTAssertNil(alert)
        XCTAssertEqual(vm.lastStatusMessage, "marker")
        XCTAssertTrue(vm.isRemoving)
    }

    func test_테스트용_StoreKit_설정파일은_앱번들에_포함되지않는다() {
        let appBundle = Bundle(for: AppsViewModel.self)
        XCTAssertNil(appBundle.url(forResource: "TriClean", withExtension: "storekit"))
    }

    // MARK: - 설치 상태

    func test_원래경로의_번들존재여부를_확정할수있을때만_없음으로본다() throws {
        let apps = library.deletingLastPathComponent().appendingPathComponent("Applications", isDirectory: true)
        let installed = apps.appendingPathComponent("Foo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)

        XCTAssertEqual(AppsViewModel.bundlePresence(atPath: installed.path), .present)
        XCTAssertEqual(AppsViewModel.bundlePresence(atPath: apps.appendingPathComponent("Gone.app").path), .absent)
        // 상위 폴더가 없으면(분리된 외장 디스크 등) 제거됐다고 단정하지 않는다.
        XCTAssertEqual(
            AppsViewModel.bundlePresence(atPath: library.deletingLastPathComponent()
                .appendingPathComponent("Volumes/Ext/Applications/Foo.app").path),
            .unknown
        )
    }

    // MARK: - 비동기 스캔 상태

    private func info(_ path: String) -> AppsSelectedAppInfo {
        AppsSelectedAppInfo(name: "App", bundleID: bundleID, appPath: path, modifiedDate: nil)
    }

    private func item(_ name: String) -> AppsRelatedItem {
        AppsRelatedItem(url: URL(fileURLWithPath: "/tmp/\(name)"), selected: false, isDirectory: true)
    }

    func test_Details를_닫으면_스캔을_취소하고_결과를_반영하지않는다() async {
        let vm = AppsViewModel()
        let app = AppsInstalledApp(
            name: "Foo", bundleID: bundleID, url: URL(fileURLWithPath: "/Applications/Foo.app"),
            canUninstall: true, isSystemApp: false, isAppStoreApp: false, modifiedDate: nil
        )
        vm.installedApps = [app]
        vm.selectedInstalledAppIDs = [app.id]
        vm.selectedApp = info("/Applications/Foo.app")
        let late = item("late")

        let task = vm.beginRelatedScan(appPath: "/Applications/Foo.app", libraryRoot: nil) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return [late]
        }
        XCTAssertTrue(vm.isScanning)

        vm.relatedDetailsDismissed()
        await task.value

        XCTAssertFalse(vm.isScanning)
        XCTAssertTrue(vm.relatedItems.isEmpty)
        XCTAssertNil(vm.selectedApp)
        // 앱 목록과 체크 상태는 그대로다.
        XCTAssertEqual(vm.installedApps.map(\.id), [app.id])
        XCTAssertEqual(vm.selectedInstalledAppIDs, [app.id])
    }

    func test_다른앱을_고르면_이전앱의_늦은_스캔결과를_반영하지않는다() async {
        let vm = AppsViewModel()
        vm.selectedApp = info("/Applications/A.app")
        let fromA = item("from-a")

        // 취소되지 않는 지연으로 A의 결과가 B로 바뀐 뒤에 도착하게 한다.
        let taskA = vm.beginRelatedScan(appPath: "/Applications/A.app", libraryRoot: nil) {
            await Task.detached { try? await Task.sleep(nanoseconds: 300_000_000) }.value
            return [fromA]
        }
        vm.selectedApp = info("/Applications/B.app")
        await taskA.value

        XCTAssertTrue(vm.relatedItems.isEmpty)
    }

    func test_새스캔이_시작되면_이전스캔결과가_섞이지않는다() async {
        let vm = AppsViewModel()
        vm.selectedApp = info("/Applications/A.app")
        let fromA = item("from-a")
        let fromB = item("from-b")

        let taskA = vm.beginRelatedScan(appPath: "/Applications/A.app", libraryRoot: nil) {
            await Task.detached { try? await Task.sleep(nanoseconds: 300_000_000) }.value
            return [fromA]
        }
        vm.selectedApp = info("/Applications/B.app")
        let taskB = vm.beginRelatedScan(appPath: "/Applications/B.app", libraryRoot: nil) { [fromB] }

        await taskB.value
        await taskA.value

        XCTAssertEqual(vm.relatedItems.map(\.id), [fromB.id])
        XCTAssertFalse(vm.isScanning)
    }
}
