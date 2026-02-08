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

// ✅ 체험판 남은 기간을 보여주는 간단한 배너
struct TrialBannerView: View {
    let daysLeft: Int
    
    var body: some View {
        Text("trial.banner.status".localized(with: daysLeft))
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.red.opacity(0.85))
            .foregroundColor(.white)
            .clipShape(Capsule())
            .shadow(radius: 2)
            .padding()
    }
}

@main
struct TriCleanApp: App {

    // ✅ 앱 상태 관리 객체들 (구매 관리, 체험 기간 관리, 메모리 뷰모델)
    @StateObject private var memoryViewModel = MemoryViewModel()
    @StateObject private var storeManager = StoreManager.shared
    @StateObject private var trialManager = TrialManager.shared
    @State private var showPaywallSheet: Bool = false

    private let minWindowContentSize = NSSize(width: 1024, height: 820)

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        // 메인 윈도우
        WindowGroup {
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

                } else if storeManager.isPurchased || !trialManager.isTrialExpired {
                    // (구매 완료) OR (체험 기간 유효) -> 정상 화면
                    ContentView()
                        .overlay(alignment: .bottomTrailing) {
                            // 아직 구매하지 않은 체험판 사용자에게 남은 기간 표시
                            if !storeManager.isPurchased {
                                TrialBannerView(daysLeft: trialManager.daysRemaining)
                                    .onTapGesture {
                                        openPaywallWindow()
                                    }
                            }
                        }

                } else {
                    // 체험 기간 만료 + 미구매 사용자 -> 루트 Paywall 표시(닫기 버튼 없음)
                    PaywallView(allowDismiss: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // ✅ 창 최소 크기 강제(사용자가 강제로 줄여도 깨지지 않도록)
            .background(WindowMinSizeSetter(minContentSize: minWindowContentSize))
            // ✅ 레이아웃 최소치(콘텐츠)
            .frame(minWidth: minWindowContentSize.width, minHeight: minWindowContentSize.height)
            // ✅ EnvironmentObject 주입(하위 뷰에서 공통 사용)
            .environmentObject(memoryViewModel)
            .environmentObject(storeManager)
            .environmentObject(trialManager)
            // ✅ 체험 중에는 Paywall을 시트로 띄움
            .sheet(isPresented: $showPaywallSheet) {
                PaywallView(allowDismiss: true)
                    .environmentObject(storeManager)
            }
        }
        .commands {
            // 메뉴바에 '라이선스' 관련 메뉴 추가 (선택 사항)
            CommandGroup(after: .appInfo) {
                if !storeManager.isPurchased {
                    Button("menu.buy_pro".localized) {
                        openPaywallWindow()
                    }
                }
            }
        }

        // 메뉴바 (상태 표시줄 아이콘)
        MenuBarExtra {
            // 메뉴바 팝업 내용
            if storeManager.isPurchased || !trialManager.isTrialExpired {
                MenuMemoryView()
                    .environmentObject(memoryViewModel)
            } else {
                // 체험판 만료 시 메뉴바 기능 제한
                VStack(spacing: 12) {
                    Text("trial.expired.msg".localized)
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Button("trial.expired.btn".localized) {
                        NSApp.activate(ignoringOtherApps: true)
                        openPaywallWindow()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        } label: {
            // ✅ 고정된 "%" 대신 ViewModel의 설정된 단위(%, MB)를 따라감
            Text(memoryViewModel.formattedCurrentUsage)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }

    // ✅ 결제창 띄우기 헬퍼: 체험 중에는 "시트"로, 만료 시에는 앱 활성화만 수행(이미 루트 Paywall)
    private func openPaywallWindow() {
        NSApp.activate(ignoringOtherApps: true)

        // 이미 구매 완료면 아무 동작도 하지 않음
        guard !storeManager.isPurchased else { return }

        // 체험 만료라면 루트 Paywall이 이미 떠 있으니 활성화만
        guard !trialManager.isTrialExpired else { return }

        // 체험 중(미구매)이라면 Paywall 시트를 띄움
        showPaywallSheet = true
     }

}
