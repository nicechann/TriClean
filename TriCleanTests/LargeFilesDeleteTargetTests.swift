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
    /// 작업 스레드가 제한 시간 안에 멈추지 않았으면 임시 폴더를 지우지 않는다.
    /// 아직 쓰고 있는 폴더를 지우면 스레드가 다른 테스트의 파일 시스템 상태와 섞일 수 있다.
    private var preservesTemporaryFolder = false

    override func setUpWithError() throws {
        preservesTemporaryFolder = false
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
        guard !preservesTemporaryFolder else { return }
        try? FileManager.default.removeItem(at: home)
    }

    /// 작업 스레드를 멈추고 끝날 때까지 기다린다. 제한 시간을 넘기면 실패로 기록하고 임시 폴더를 남긴다.
    private func stopWorker(_ worker: FileChurnWorker, file: StaticString = #filePath, line: UInt = #line) {
        guard worker.stop(timeout: 10) else {
            XCTFail("파일 생성·삭제 스레드가 10초 안에 끝나지 않았습니다", file: file, line: line)
            preservesTemporaryFolder = true
            return
        }
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
    func test_스캔후_추가된_보관함은_삭제직전에_차단한다() throws {
        let item = folder("Work")
        XCTAssertEqual(LargeFilesViewModel.deletionPreflight(item), .proceed)
        try FileManager.default.createDirectory(
            at: item.url.appendingPathComponent(".hidden/Photos.photoslibrary"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(LargeFilesViewModel.deletionPreflight(item), .skip)
    }

    func test_불완전한_스캔결과는_상위폴더_삭제대상에서_제외한다() {
        let item = FolderInfo(url: home.appendingPathComponent("Work"), sizeBytes: 100,
                              isDirectory: true, isScanComplete: false)
        let prepared = LargeFilesViewModel.prepareDeleteTargets([item], home: home)
        XCTAssertTrue(prepared.targets.isEmpty)
        // 보호 위치와는 안내 문구가 달라야 하므로 따로 센다.
        XCTAssertEqual(prepared.protectedCount, 0)
        XCTAssertEqual(prepared.incompleteCount, 1)
        XCTAssertEqual(LargeFilesViewModel.deletionPreflight(item), .skip)
    }

    func test_잠금사유는_보호위치를_우선하고_불완전과_구분한다() {
        let incomplete = FolderInfo(url: home.appendingPathComponent("Work"), sizeBytes: 100,
                                    isDirectory: true, isScanComplete: false)
        let protectedAndIncomplete = FolderInfo(url: home.appendingPathComponent("Pictures"), sizeBytes: 100,
                                                isDirectory: true, isScanComplete: false)
        XCTAssertEqual(LargeFilesViewModel.deleteLock(for: incomplete, home: home), .incomplete)
        XCTAssertEqual(LargeFilesViewModel.deleteLock(for: protectedAndIncomplete, home: home), .protected)
        XCTAssertNil(LargeFilesViewModel.deleteLock(for: folder("Work/a"), home: home))

        let prepared = LargeFilesViewModel.prepareDeleteTargets(
            [incomplete, protectedAndIncomplete, folder("Documents/Project")], home: home
        )
        XCTAssertEqual(names(prepared.targets), ["Documents/Project"])
        XCTAssertEqual(prepared.protectedCount, 1)
        XCTAssertEqual(prepared.incompleteCount, 1)
    }

    func test_사라진_항목_오류만_순회를_계속할_오류로_본다() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                            userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertTrue(LargeFilesViewModel.isVanishedItemError(cocoa))
        XCTAssertTrue(LargeFilesViewModel.isVanishedItemError(posix))
        XCTAssertTrue(LargeFilesViewModel.isVanishedItemError(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: posix])
        ))
        XCTAssertFalse(LargeFilesViewModel.isVanishedItemError(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        ))
        XCTAssertFalse(LargeFilesViewModel.isVanishedItemError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    /// 빌드 산출물·캐시처럼 내용이 계속 바뀌는 폴더도 삭제 직전 확인을 통과해야 한다.
    /// 수정 전에는 순회 중 사라진 하위 폴더 때문에 약 15~20%가 `.skip`으로 빠졌다.
    func test_내용이_계속_바뀌는_폴더도_삭제직전_확인을_통과한다() throws {
        let item = folder("Work")
        for index in 0..<20 {
            try FileManager.default.createDirectory(
                at: item.url.appendingPathComponent("d\(index)"), withIntermediateDirectories: true
            )
        }
        let worker = FileChurnWorker(root: item.url, folderCount: 20)
        worker.start()
        // tearDown이 폴더를 지우기 전에 마지막 파일 작업까지 끝나야 한다.
        defer { stopWorker(worker) }

        for _ in 0..<60 {
            XCTAssertEqual(LargeFilesViewModel.deletionPreflight(item), .proceed)
        }
    }

    func test_작업스레드는_정지후_폴더를_건드리지_않는다() throws {
        let root = home.appendingPathComponent("Churn", isDirectory: true)
        for index in 0..<4 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("d\(index)"), withIntermediateDirectories: true
            )
        }
        let worker = FileChurnWorker(root: root, folderCount: 4)
        worker.start()
        Thread.sleep(forTimeInterval: 0.05)
        stopWorker(worker)
        XCTAssertTrue(worker.isFinished)

        // 정지가 확인된 뒤에는 폴더 내용이 더 바뀌지 않아야 한다.
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        Thread.sleep(forTimeInterval: 0.1)
        let after = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(before, after)

        // 폴더가 사라져도 작업 스레드가 상위 경로를 다시 만들지 않는다.
        try FileManager.default.removeItem(at: root)
        let orphan = FileChurnWorker(root: root, folderCount: 4)
        orphan.start()
        Thread.sleep(forTimeInterval: 0.05)
        stopWorker(orphan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func test_하위폴더를_읽지못하면_스캔과_삭제검증이_불완전함을_감지한다() async throws {
        let blocked = home.appendingPathComponent("Work/blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: home.appendingPathComponent("Work/file.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        if (try? FileManager.default.contentsOfDirectory(atPath: blocked.path)) != nil {
            throw XCTSkip("This environment can read permission-restricted directories")
        }
        var results: [FolderInfo] = []
        for await batch in LargeFilesViewModel.scanStructuredItemsBatches(
            of: home, minSizeMB: 0, ignoredFolderURLs: [], batchSize: 50
        ) { results.append(contentsOf: batch) }
        let work = try XCTUnwrap(results.first { $0.url.lastPathComponent == "Work" })
        XCTAssertFalse(work.isScanComplete)
        XCTAssertEqual(LargeFilesViewModel.deletionPreflight(folder("Work")), .skip)
    }

    func test_폴백직전에_추가된_보관함도_이동하지않는다() async throws {
        let item = folder("Work")
        let library = item.url.appendingPathComponent("Photos.photoslibrary")
        let mover = TrashService.Mover(
            trashItem: { _ in
                try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            },
            recycle: { _ in XCTFail("Protected library must not reach recycle"); return nil }
        )
        let outcome = await TrashService.sanitizeAndMoveToTrash(
            [item], scopes: [.descendants(of: home)], url: \.url, identity: \.fileIdentity,
            allowsDirectoryContentChanges: { $0.isDirectory }, logCategory: "LargeFilesTests",
            preflight: { LargeFilesViewModel.deletionPreflight($0) }, mover: mover
        )
        XCTAssertTrue(outcome.succeeded.isEmpty)
        XCTAssertEqual(outcome.excludedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
    }

}

/// 폴더 안에서 임시 항목을 계속 만들고 지우는 작업 스레드(내용이 바뀌는 폴더 재현용).
///
/// - 정지는 `stop(timeout:)` 한 곳에서 요청하고, 스레드가 실제로 끝났는지 기다려 확인한다.
/// - 파일 작업마다 정지 요청을 다시 확인하므로 정지 요청 뒤에는 새 작업을 시작하지 않는다.
/// - `root/dN`이 이미 있을 때만 그 안에 만든다(중간 경로를 만들지 않는다). 테스트가 폴더를
///   지운 뒤에 스레드가 남아 있어도 경로를 다시 만들어 다른 테스트와 섞이지 않는다.
private final class FileChurnWorker: @unchecked Sendable {
    private let root: URL
    private let folderCount: Int
    private let lock = NSLock()
    private var stopRequested = false
    private var finished = false
    private let finishedSignal = DispatchSemaphore(value: 0)

    init(root: URL, folderCount: Int) {
        self.root = root
        self.folderCount = folderCount
    }

    /// `NSLocking.withLock`은 macOS 14부터라 배포 대상(13.5)에 맞춰 직접 잠근다.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var isFinished: Bool { locked { finished } }
    private var shouldStop: Bool { locked { stopRequested } }

    func start() {
        let thread = Thread { [self] in run() }
        thread.start()
    }

    /// 정지를 요청하고 끝날 때까지 기다린다. 제한 시간 안에 끝났으면 true.
    func stop(timeout: TimeInterval) -> Bool {
        locked { stopRequested = true }
        if isFinished { return true }
        guard finishedSignal.wait(timeout: .now() + timeout) == .success else { return false }
        // 여러 번 불려도 결과가 같도록 신호를 되돌려 둔다.
        finishedSignal.signal()
        return true
    }

    private func run() {
        defer {
            locked { finished = true }
            finishedSignal.signal()
        }
        let fm = FileManager.default
        var counter = 0
        while !shouldStop {
            let parent = root.appendingPathComponent("d\(counter % folderCount)", isDirectory: true)
            let temp = parent.appendingPathComponent("tmp\(counter % 200)", isDirectory: true)
            counter += 1
            guard fm.fileExists(atPath: parent.path) else { continue }
            if fm.fileExists(atPath: temp.path) {
                try? fm.removeItem(at: temp)
            } else {
                guard (try? fm.createDirectory(at: temp, withIntermediateDirectories: false)) != nil,
                      !shouldStop else { continue }
                fm.createFile(atPath: temp.appendingPathComponent("x").path, contents: Data([1]))
            }
        }
    }
}
