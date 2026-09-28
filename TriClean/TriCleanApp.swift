//
//  TriCleanApp.swift
//  TriClean
//
//  Created by changyu Kang on 08/12/2025.
//

import SwiftUI
import AppKit

/// macOS에서 SwiftUI의 `.frame(minWidth:minHeight:)`는 "콘텐츠 레이아웃" 최소치일 뿐,
/// 윈도우 자체의 최소 크기를 강제하지 않습니다.
/// 실제 창 크기 제한을 위해 NSWindow의 `contentMinSize`/`minSize`를 설정합니다.
private struct WindowMinSizeSetter: NSViewRepresentable {
    let minContentSize: NSSize

    /// 창에 실제로 부착되는 시점을 직접 잡아내는 컨테이너.
    ///
    /// 기존에는 `makeNSView`에서 `DispatchQueue.main.async`로 한 박자 미뤄 `view.window`가
    /// 채워지기를 기대했다. 그러나 `@Sendable` 클로저가 비-Sendable한 `NSView`를 캡처하는
    /// 구조라 Swift 6에서 에러이고, 지연 실행 시점에 window가 아직 없으면 `apply`가
    /// 조용히 빠져나가 최소 크기가 적용되지 않는다.
    /// `viewDidMoveToWindow`는 부착 직후 정확히 한 번 호출되므로 타이밍 추측이 필요 없다.
    final class MinSizeProbeView: NSView {
        var onAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onAttach?(window) }
        }
    }

    func makeNSView(context: Context) -> MinSizeProbeView {
        let view = MinSizeProbeView(frame: .zero)
        let size = minContentSize
        view.onAttach = { window in
            Self.apply(minContentSize: size, to: window)
        }
        return view
    }

    func updateNSView(_ nsView: MinSizeProbeView, context: Context) {
        let size = minContentSize
        nsView.onAttach = { window in
            Self.apply(minContentSize: size, to: window)
        }
        // 이미 부착된 뒤 값이 바뀐 경우를 위해 즉시 한 번 더 적용한다.
        if let window = nsView.window {
            Self.apply(minContentSize: size, to: window)
        }
    }

    private static func apply(minContentSize: NSSize, to window: NSWindow) {

        // 콘텐츠 기준 최소 크기
        window.contentMinSize = minContentSize

        // 프레임 기준 최소 크기(타이틀바 포함)
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minContentSize)).size
        window.minSize = frameSize
    }
}

@main
struct TriCleanApp: App {
    
    // 앱 상태 관리 객체들
    @StateObject private var memoryViewModel = MemoryViewModel()
    @StateObject private var storeManager = StoreManager.shared

    // ✅ [공유 스캐너 모델] SmartScan과 각 상세 탭(Storage/Duplicates/Apps)이
    //   같은 인스턴스를 공유하도록 앱 레벨에서 한 번만 생성해 EnvironmentObject로 주입.
    //   (기존: 각 화면이 @StateObject로 따로 생성 → 스캔 결과가 탭 간 공유되지 않던 문제 해결)
    @StateObject private var junkViewModel = JunkScannerViewModel()
    @StateObject private var duplicateViewModel = DuplicateScannerViewModel()
    @StateObject private var appsViewModel = AppsViewModel()
    @StateObject private var photoViewModel = PhotoScannerViewModel()
    // 대용량 파일 화면도 같은 이유로 앱 레벨에서 보유한다. 뷰가 상태를 들고 있으면
    // 탭 전환 시 스캔 Task가 취소되지 않은 채 남고 결과도 매번 사라진다.
    @StateObject private var largeFilesViewModel = LargeFilesViewModel()
    // ✅ 주간 정리 리마인더 매니저 (다른 매니저와 동일하게 .shared 싱글톤을 주입)
    @StateObject private var reminderManager = CleanupReminderManager.shared
    @State private var showPaywallSheet: Bool = false
    @AppStorage("didShowOnboarding") private var didShowOnboarding = false
    @State private var showOnboarding = false
    
    @Environment(\.openWindow) private var openWindow
    // ✅ [추가] scenePhase 감지를 위해 환경 변수 선언 (에러 해결)
    @Environment(\.scenePhase) private var scenePhase
    
    /// ⚠️ 이 값은 NSWindow.minSize로 **강제**되므로 사용자가 더 줄일 수 없다.
    ///   배포 타깃(macOS 13.5)에는 1280×800 해상도의 13인치 MacBook이 포함된다.
    ///   기존 840은 타이틀바(약 28pt)와 메뉴 막대(25pt)를 더하면 화면 높이 800을 넘어
    ///   창 하단(업그레이드 배너를 붙인 safeAreaInset)이 잘렸다.
    ///   1280×800에서도 여백이 남도록 낮춘다.
    private let minWindowContentSize = NSSize(width: 1000, height: 700)

    // ✅ 사용자 서체 설정. SettingsView와 같은 키를 공유하며,
    //    두 Scene(메인 창·메뉴바 팝오버)에 동일하게 주입한다.
    @AppStorage(AppTypography.StorageKey.scale)
    private var fontScaleRawValue: String = AppFontScale.standard.rawValue
    @AppStorage(AppTypography.StorageKey.design)
    private var fontDesignRawValue: String = AppFontDesign.standard.rawValue

    // ✅ 메뉴 막대 표시 여부.
    //    꺼도 Dock 아이콘이 남아 있어(LSUIElement 미설정)
    //    앱에 접근할 경로가 사라지지 않는다.
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true

    private var typography: AppTypography {
        AppTypography.resolve(
            scaleRawValue: fontScaleRawValue,
            designRawValue: fontDesignRawValue
        )
    }
    
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    var body: some Scene {
        // 메인 윈도우
        WindowGroup(id: "main") {
            ZStack {
                // ✅ 초기 구매상태 로딩 전에는 로딩 화면을 보여서 Paywall 깜빡임 방지
                if !storeManager.hasLoadedPurchaseState {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("store.status.checking".localized)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                } else {
                    // 스캔과 분석은 무료로 제공하고, 실제 삭제·정리 실행만 구매 상태에서 허용합니다.
                    ContentView()
                        .onAppear {
                            if !didShowOnboarding {
                                didShowOnboarding = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    showOnboarding = true
                                }
                            }
                        }
                }
            }
            // ✅ 창 최소 크기 강제(사용자가 강제로 줄여도 깨지지 않도록)
            .background(WindowMinSizeSetter(minContentSize: minWindowContentSize))
            // ✅ 레이아웃 최소치(콘텐츠)
            .frame(minWidth: minWindowContentSize.width, minHeight: minWindowContentSize.height)
            // ✅ EnvironmentObject 주입(하위 뷰에서 공통 사용)
            .environmentObject(memoryViewModel)
            .environmentObject(storeManager)
            // ✅ 공유 스캐너 모델 주입
            .environmentObject(junkViewModel)
            .environmentObject(duplicateViewModel)
            .environmentObject(appsViewModel)
            .environmentObject(photoViewModel)
            .environmentObject(largeFilesViewModel)
            .environmentObject(reminderManager)
            // ✅ 별도 폰트 지정이 없는 기본 Text/Label도 사용자 설정을 따르도록
            //    앱 전역의 기본 본문 폰트를 먼저 지정한다. 개별 .appFont(...)는 이를 덮어쓴다.
            .appFont(.body)
            // ✅ 사용자 서체 설정 주입 — 위 기본 폰트와 개별 .appFont(...)이 이 값을 읽는다.
            .environment(\.appTypography, typography)
            // 결제창 표시
            .sheet(isPresented: $showPaywallSheet) {
                PaywallView()
                    .environmentObject(storeManager)
                    .appFont(.body)
                    .environment(\.appTypography, typography)
            }
            // ✅ 첫 실행 온보딩
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(isPresented: $showOnboarding)
                    .appFont(.body)
                    .environment(\.appTypography, typography)
            }
            .onValueChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    // ✅ 시스템 설정에서 알림 권한이 바뀌었을 수 있으므로 활성화 시 예약을 보정
                    reminderManager.refreshSchedule()
                }
            }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                if !storeManager.isPurchased {
                    Button("menu.buy_pro".localized) {
                        openPaywallWindow()
                    }
                    Divider()
                }

                if let privacyURL = AppLinks.privacyPolicy {
                    Link("paywall.link.privacy".localized, destination: privacyURL)
                }
                if let termsURL = AppLinks.termsOfUse {
                    Link("paywall.link.terms".localized, destination: termsURL)
                }
                if let supportURL = AppLinks.supportPage {
                    Link("settings.support_link".localized, destination: supportURL)
                }
            }
        }
        
        // 메뉴바 (상태 표시줄 아이콘)
        // ✅ 설정 ▸ 표시에서 끄면 isInserted가 false가 되어 항목이 제거된다.
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            // 메뉴바 팝업 내용
            MenuMemoryView()
                .environmentObject(memoryViewModel)
                .appFont(.body)
                .environment(\.appTypography, typography)
        } label: {
            // ⚠️ label은 시스템 메뉴바 안이라 높이가 고정이다.
            //    배율을 적용하면 글자가 잘리므로 고정 크기를 유지한다.
            // ✅ 고정된 "%" 대신 ViewModel의 설정된 단위(%, MB)를 따라감
            Text(memoryViewModel.formattedCurrentUsage)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
    
    // 미구매 사용자가 삭제·정리 기능을 선택했을 때 결제창을 표시합니다.
    private func openPaywallWindow() {
        NSApp.activate(ignoringOtherApps: true)
        
        // 메인 윈도우가 닫혀 있으면 새로 열고, 이미 있으면 앞으로 가져오기
        // ⚠️ 단순히 "보이는 첫 창"을 고르면 항상 떠 있는 메뉴바(MenuBarExtra) 창이 잡혀
        //    메인 창이 없는데도 openWindow가 호출되지 않고, 시트를 띄울 창이 없어 결제창이 뜨지 않았다.
        //    메인 창이 될 수 있는 일반 창만 대상으로 삼는다.
        let mainWindow = NSApp.windows.first { window in
            window.canBecomeMain && !(window is NSPanel) && (window.isVisible || window.isMiniaturized)
        }
        if let window = mainWindow {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        
        guard !storeManager.isPurchased else { return }
        
        showPaywallSheet = true
    }
}
