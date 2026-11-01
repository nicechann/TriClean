//
//  DemoMode.swift
//  TriClean
//
//  App Store 미리보기 영상 녹화용 데모 모드 (DEBUG 빌드 전용).
//  `TRICLEAN_DEMO=1`로 실행하면 실제 디스크를 스캔하지 않고 가상 데이터로 화면을 채운 뒤
//  정해진 순서로 화면을 넘긴다. 녹화 도구가 표준 출력의 `DEMO_*` 줄로 타이밍을 맞춘다.
//  삭제·정리 동작은 호출하지 않으며, 모든 경로는 존재하지 않는 `/Users/demo` 아래를 가리킨다.
//

#if DEBUG
import SwiftUI
import Combine

enum DemoMode {
    static let isActive = ProcessInfo.processInfo.environment["TRICLEAN_DEMO"] == "1"

    /// 컴팩트 레이아웃의 앱 상세 시트를 여는 신호(시트 상태는 `AppsView` 내부 @State라 직접 바꿀 수 없다).
    static let appDetailsRequests = PassthroughSubject<Void, Never>()

    static let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
    static let library = home.appendingPathComponent("Library", isDirectory: true)
    static let windowSize = NSSize(width: 1400, height: 850)

    private static let GB: Int64 = 1_000_000_000
    private static let MB: Int64 = 1_000_000
    private static let KB: Int64 = 1_000

    static func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }

    private static func daysAgo(_ days: Double) -> Date {
        Date().addingTimeInterval(-days * 86_400)
    }

    // MARK: - 정크

    static func junkResults() -> [JunkScanResult] {
        let entries: [String: [(String, Int64)]] = [
            "system_caches": [
                ("com.pixelforge.app", 1_240 * MB),
                ("com.streamly.desktop", 860 * MB),
                ("com.codenest.editor", 640 * MB),
                ("Homebrew", 418 * MB),
                ("com.meetup.pro", 212 * MB)
            ],
            "system_logs": [
                ("CoreSimulator", 386 * MB),
                ("MeetUp Pro", 94 * MB),
                ("Chirp", 27 * MB)
            ],
            "xcode_derived": [
                ("Notely-gqbyfmzwzrxk", 3_420 * MB),
                ("Widgets-bxwvdlkqmpas", 1_780 * MB)
            ],
            "saved_app_state": [
                ("com.codenest.editor.savedState", 48 * MB),
                ("com.pixelforge.app.savedState", 21 * MB)
            ],
            "http_storage": [
                ("com.streamly.desktop", 64 * MB),
                ("com.chirp.mac", 18 * MB)
            ]
        ]

        return JunkCategory.defaultCategories.compactMap { category in
            guard let list = entries[category.id], let relative = category.relativePaths.first else { return nil }
            let root = library.appendingPathComponent(relative, isDirectory: true)
            let items = list.map { name, size in
                JunkItem(
                    url: root.appendingPathComponent(name),
                    sizeBytes: size,
                    categoryID: category.id,
                    scanRoot: root,
                    isSelected: category.riskLevel.defaultSelected
                )
            }
            return JunkScanResult(id: category.id, category: category, items: items)
        }
    }

    // MARK: - 대용량 파일

    static func largeFileResults() -> [FolderInfo] {
        let tree: [(String, Int64, [(String, Int64)])] = [
            ("Movies", 48_200 * MB, [("여행 2025.mov", 12_400 * MB), ("화면 기록 2026-09-14.mov", 6_800 * MB)]),
            ("Downloads", 31_500 * MB, [("Xcode_26.xip", 11_900 * MB), ("ubuntu-24.04-desktop.iso", 6_100 * MB)]),
            ("Documents", 22_800 * MB, [("프로젝트 아카이브.zip", 4_200 * MB), ("강의 녹화.mp4", 3_300 * MB)]),
            ("Developer", 18_400 * MB, [("simulator-runtime.dmg", 7_900 * MB)]),
            ("Pictures", 14_100 * MB, [("RAW Export.zip", 2_400 * MB)]),
            ("Music", 9_600 * MB, []),
            ("Desktop", 3_800 * MB, [("발표 영상 원본.mov", 1_900 * MB)])
        ]

        var output: [FolderInfo] = []
        for (name, size, children) in tree {
            let folder = home.appendingPathComponent(name, isDirectory: true)
            output.append(FolderInfo(url: folder, sizeBytes: size, isDirectory: true))
            for (child, childSize) in children {
                output.append(FolderInfo(
                    url: folder.appendingPathComponent(child),
                    sizeBytes: childSize,
                    isDirectory: false,
                    depth: 1,
                    parentURL: folder
                ))
            }
        }
        output.append(FolderInfo(url: home.appendingPathComponent("Windows11.vhdx"), sizeBytes: 20_400 * MB, isDirectory: false))
        return output
    }

    // MARK: - 중복 파일

    static func duplicateGroups() -> [DuplicateGroup] {
        let specs: [(String, Int64, [String])] = [
            ("Xcode_26.xip", 11_900 * MB, ["Downloads", "Downloads/old"]),
            ("회의 녹음 0912.m4a", 86 * MB, ["Documents/회의", "Desktop"]),
            ("발표자료_최종.pptx", 48 * MB, ["Documents", "Downloads", "Desktop"]),
            ("Wallpaper 5K.png", 24 * MB, ["Pictures", "Downloads"]),
            ("IMG_4821.HEIC", 3_100 * KB, ["Pictures/Export", "Downloads", "Desktop"]),
            ("계약서_서명본.pdf", 2_400 * KB, ["Documents/계약", "Downloads", "Desktop"])
        ]

        return specs.enumerated().map { index, spec in
            let (name, size, folders) = spec
            let files = folders.enumerated().map { position, folder in
                DuplicateFile(
                    url: home.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name),
                    modificationDate: daysAgo(Double(index * 9 + position * 3 + 2)),
                    isKeep: position == 0
                )
            }
            let hash = String(repeating: String(format: "%02x", 0x3a + index * 17), count: 32)
            return DuplicateGroup(hash: hash, fileSize: size, files: files)
        }
    }

    // MARK: - 앱

    static let applicationsFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)

    static func installedApps() -> [AppsInstalledApp] {
        let apps: [(String, String, Bool, Bool, Bool, Double)] = [
            // 이름, 번들 ID, 삭제 가능, 시스템, App Store, 수정일(일 전)
            ("Archivio", "com.archivio.mac", true, false, false, 64),
            ("Chirp", "com.chirp.mac", true, false, false, 12),
            ("CodeNest", "com.codenest.editor", true, false, false, 3),
            ("MeetUp Pro", "com.meetup.pro", true, false, false, 41),
            ("Notely", "com.notely.app", false, false, true, 20),
            ("PixelForge", "com.pixelforge.app", true, false, false, 186),
            ("Safari", "com.apple.Safari", false, true, false, 30),
            ("Sketchbook", "com.sketchbook.studio", true, false, false, 97),
            ("Streamly", "com.streamly.desktop", true, false, false, 8),
            ("VideoKit", "com.videokit.player", true, false, false, 220),
            ("Xcode", "com.apple.dt.Xcode", false, false, true, 15)
        ]
        return apps.map { name, bundleID, canUninstall, isSystem, isAppStore, age in
            AppsInstalledApp(
                name: name,
                bundleID: bundleID,
                url: applicationsFolder.appendingPathComponent("\(name).app", isDirectory: true),
                canUninstall: canUninstall,
                isSystemApp: isSystem,
                isAppStoreApp: isAppStore,
                modifiedDate: daysAgo(age)
            )
        }
    }

    static func relatedItems(for bundleID: String, name: String) -> [AppsRelatedItem] {
        let specs: [(String, Bool, Int64)] = [
            ("Application Support/\(name)", true, 1_420 * MB),
            ("Caches/\(bundleID)", true, 618 * MB),
            ("Logs/\(name)", true, 48 * MB),
            ("HTTPStorages/\(bundleID)", true, 3_200 * KB),
            ("Saved Application State/\(bundleID).savedState", true, 2_100 * KB),
            ("Preferences/\(bundleID).plist", false, 12 * KB)
        ]
        return specs.map { relative, isDirectory, size in
            AppsRelatedItem(
                url: library.appendingPathComponent(relative, isDirectory: isDirectory),
                selected: true,
                isDirectory: isDirectory,
                sizeBytes: size,
                isDefaultSelectable: true
            )
        }
    }
}

// MARK: - Director

/// 데모 시나리오를 진행한다. `ContentView`에 붙어 화면 선택(`selection`)과 공유 뷰 모델을 조작한다.
struct DemoDirector: ViewModifier {
    @Binding var selection: SidebarItem?

    @EnvironmentObject private var storeManager: StoreManager
    @EnvironmentObject private var junkViewModel: JunkScannerViewModel
    @EnvironmentObject private var duplicateViewModel: DuplicateScannerViewModel
    @EnvironmentObject private var appsViewModel: AppsViewModel
    @EnvironmentObject private var largeFilesViewModel: LargeFilesViewModel

    @State private var didStart = false

    func body(content: Content) -> some View {
        content.onAppear {
            guard DemoMode.isActive, !didStart else { return }
            didStart = true
            Task { await run() }
        }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func caption(_ text: String) {
        refocus()
        DemoMode.emit("DEMO_CAPTION \(text)")
    }

    /// 녹화 중 다른 앱이 앞으로 나오면 비활성 창 색으로 찍히므로 장면마다 다시 앞으로 가져온다.
    private func refocus() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.sheetParent == nil }) {
            // 시트가 떠 있으면 시트가 키 창이어야 시트 안의 컨트롤이 활성 색으로 보인다.
            (window.attachedSheet ?? window).makeKeyAndOrderFront(nil)
        }
        DemoMode.emit("DEMO_FOCUS active=\(NSApp.isActive)")
    }

    private func prepareWindow() -> NSWindow? {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else {
            return nil
        }
        let screen = NSScreen.screens.first ?? window.screen
        let visible = screen?.visibleFrame ?? .zero
        let size = DemoMode.windowSize
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    @MainActor
    private func run() async {
        let originalPurchaseOverride = storeManager.debugPurchaseOverride
        storeManager.debugPurchaseOverride = true

        // 시작 화면: 권한은 받은 상태, 결과는 비어 있음
        junkViewModel.libraryURL = DemoMode.library
        junkViewModel.results = []
        duplicateViewModel.scanFolderURL = DemoMode.home
        duplicateViewModel.groups = []
        duplicateViewModel.phase = .idle
        appsViewModel.applyDemoScopes(applications: DemoMode.applicationsFolder, library: DemoMode.library)
        appsViewModel.installedApps = []
        selection = .smartScan

        await sleep(1.0)
        guard let window = prepareWindow() else {
            DemoMode.emit("DEMO_ERROR no window")
            return
        }
        await sleep(1.0)
        DemoMode.emit("DEMO_WINDOW \(window.windowNumber)")
        // 녹화 도구가 창을 찾고 스트림을 시작할 시간
        await sleep(3.0)

        // 1) 스마트 스캔
        DemoMode.emit("DEMO_START")
        caption("클릭 한 번으로 정리할 항목을 찾아요")
        await sleep(1.0)
        junkViewModel.isScanning = true
        junkViewModel.scanProgress = "junk.progress.scanning_format".localized(with: "junk.category.system_caches.title".localized)
        duplicateViewModel.isScanning = true
        duplicateViewModel.phase = .hashingPartial
        duplicateViewModel.statusMessage = "duplicate.phase.partial_hash".localized
        appsViewModel.isLoadingInstalledApps = true
        await sleep(1.2)
        junkViewModel.scanProgress = "junk.progress.scanning_format".localized(with: "junk.category.xcode_derived.title".localized)
        await sleep(0.8)
        junkViewModel.results = DemoMode.junkResults()
        junkViewModel.scanProgress = ""
        junkViewModel.lastScanDate = Date()
        junkViewModel.isScanning = false
        appsViewModel.installedApps = DemoMode.installedApps()
        appsViewModel.isLoadingInstalledApps = false
        await sleep(0.5)
        duplicateViewModel.groups = DemoMode.duplicateGroups()
        duplicateViewModel.applyDemoScannedCount(4_812)
        duplicateViewModel.isScanning = false
        duplicateViewModel.phase = .done
        duplicateViewModel.progress = 1
        duplicateViewModel.statusMessage = "duplicate.status.scan_complete".localized(
            with: duplicateViewModel.groups.count, duplicateViewModel.selectedReclaimableString
        )
        await sleep(2.5)

        // 2) 저장 공간 + 정크
        selection = .storage
        caption("캐시·로그를 위험도별로 안전하게 정리")
        await sleep(5.0)

        // 3) 대용량 파일
        largeFilesViewModel.applyDemoResults(folder: DemoMode.home, results: DemoMode.largeFileResults())
        selection = .largeFiles
        caption("큰 파일과 폴더를 트리맵으로 한눈에")
        await sleep(5.0)

        // 4) 중복 파일
        selection = .duplicates
        caption("내용까지 비교해 정확하게 찾는 중복 파일")
        await sleep(5.0)

        // 5) 앱 + 남은 파일
        selection = .apps
        caption("앱을 지울 때 남은 파일까지 함께")
        await sleep(1.5)
        if let app = appsViewModel.installedApps.first(where: { $0.name == "PixelForge" }) {
            appsViewModel.selectedInstalledAppIDs = [app.id]
            appsViewModel.selectedApp = AppsSelectedAppInfo(
                name: app.name, bundleID: app.bundleID, appPath: app.id, modifiedDate: app.modifiedDate
            )
            appsViewModel.relatedItems = DemoMode.relatedItems(for: app.bundleID ?? "", name: app.name)
            await sleep(0.6)
            DemoMode.appDetailsRequests.send(())
        }
        await sleep(2.6)
        caption("모든 삭제는 휴지통으로, 언제든 되돌릴 수 있어요")
        await sleep(2.8)

        DemoMode.emit("DEMO_END")
        await sleep(0.5)
        storeManager.debugPurchaseOverride = originalPurchaseOverride
        NSApp.terminate(nil)
    }
}
#endif
