//
//  TriCleanApp.swift
//  TriClean
//
//  Created by changyu Kang on 08/12/2025.
//

import SwiftUI
import AppKit

@main
struct TriCleanApp: App {

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    // ✅ 앱 전체에서 공유할 단 하나의 MemoryViewModel
    @StateObject private var memoryViewModel = MemoryViewModel()

    var body: some Scene {
        // 메인 윈도우
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .environmentObject(memoryViewModel)   // 🔹 인스턴스 #1 아님, 공용 인스턴스
        }

        // 메뉴바
        MenuBarExtra {
            // 메뉴바 팝업 내용
            MenuMemoryView()
                .environmentObject(memoryViewModel)   // 🔹 같은 인스턴스 재사용
        } label: {
            // 메뉴바에 보이는 텍스트/아이콘
            Text("\(memoryViewModel.usagePercent)%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}
