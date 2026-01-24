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

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    // ✅ 앱 전체에서 공유할 단 하나의 MemoryViewModel
    @StateObject private var memoryViewModel = MemoryViewModel()

    private let minWindowContentSize = NSSize(width: 1024, height: 820)

    var body: some Scene {
        // 메인 윈도우
        WindowGroup {
            ContentView()
                // ✅ 창 최소 크기 강제(사용자가 강제로 줄여도 깨지지 않도록)
                .background(WindowMinSizeSetter(minContentSize: minWindowContentSize))
                // ✅ 레이아웃 최소치(콘텐츠)
                .frame(minWidth: minWindowContentSize.width, minHeight: minWindowContentSize.height)
                .environmentObject(memoryViewModel)
        }

        // 메뉴바
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
}

