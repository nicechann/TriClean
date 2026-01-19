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
                .environmentObject(memoryViewModel)
        }

        // 메뉴바
        MenuBarExtra {
            // 메뉴바 팝업 내용
            MenuMemoryView()
                .environmentObject(memoryViewModel)
        } label: {
            // ✅ [수정] 고정된 "%" 대신 ViewModel의 설정된 단위(%, MB)를 따라감
            Text(memoryViewModel.formattedCurrentUsage)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}
