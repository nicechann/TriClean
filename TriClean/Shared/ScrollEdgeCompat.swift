//
//  ScrollEdgeCompat.swift
//  TriClean
//
//  macOS 26(Tahoe)부터 26 SDK로 빌드한 앱은 스크롤 콘텐츠가 윈도우 툴바/타이틀바
//  아래까지 확장되는 것이 기본 동작이다. 시스템 scroll edge effect가 적용되지 않으면
//  스크롤된 텍스트가 윈도우 제목·트래픽 라이트와 그대로 겹쳐 읽기 어려워진다.
//  (App Review Guideline 4 지적 사항 — 빌드 15, 2026-08-24)
//
//  이 헬퍼는 Tahoe 전용 API인 scrollEdgeEffectStyle(.hard)를 상단 가장자리에만
//  적용해 툴바 경계를 불투명 처리한다. 구버전 macOS에서는 겹침 자체가 발생하지
//  않으므로 아무 동작도 하지 않는다.
//
//  ⚠️ 과거 시도와의 차이 (반복 금지):
//   - 빌드 16: window.styleMask.remove(.fullSizeContentView) — AppKit 강제 변경, 폐기
//   - 빌드 17: 루트 NavigationSplitView에 .toolbarBackground(불투명 색) 전역 적용
//              → macOS 26에서 콘텐츠가 전혀 그려지지 않는 회귀(빈 화면 리젝) 유발
//  이 헬퍼는 반드시 "스크롤 뷰(ScrollView/List) 단위"로만 적용할 것.
//

import SwiftUI

extension View {
    /// 스크롤 콘텐츠가 툴바/타이틀바 아래로 지나갈 때 상단 가장자리를
    /// 불투명 처리해 텍스트 겹침을 막는다. ScrollView 또는 List에 직접 적용한다.
    @ViewBuilder
    func hardTopScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}
