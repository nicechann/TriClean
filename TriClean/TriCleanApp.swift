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

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }

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
    // ✅ 주간 정리 리마인더 매니저 (다른 매니저와 동일하게 .shared 싱글톤을 주입)
    @StateObject private var reminderManager = CleanupReminderManager.shared
    @State private var showPaywallSheet: Bool = false
    @AppStorage("didShowOnboarding") private var didShowOnboarding = false
    @State private var showOnboarding = false
    
    @Environment(\.openWindow) private var openWindow
    // ✅ [추가] scenePhase 감지를 위해 환경 변수 선언 (에러 해결)
    @Environment(\.scenePhase) private var scenePhase
    
    private let minWindowContentSize = NSSize(width: 1180, height: 840)
    
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
            .environmentObject(reminderManager)
            // 결제창 표시
            .sheet(isPresented: $showPaywallSheet) {
                PaywallView()
                    .environmentObject(storeManager)
            }
            // ✅ 첫 실행 온보딩
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(isPresented: $showOnboarding)
            }
            .onChange(of: scenePhase) { newPhase in
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
        MenuBarExtra {
            // 메뉴바 팝업 내용
            MenuMemoryView()
                .environmentObject(memoryViewModel)
        } label: {
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
        if let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        
        guard !storeManager.isPurchased else { return }
        
        showPaywallSheet = true
    }
}
