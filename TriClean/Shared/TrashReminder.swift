//
//  TrashReminder.swift
//  TriClean
//
//  모든 정리는 "휴지통으로 이동"에서 끝나므로, 휴지통을 비우기 전에는 디스크 공간이
//  실제로 늘지 않는다. 사용자가 이 사실을 앱 안에서 알 수 있도록, 휴지통으로 옮긴
//  항목 수를 모아 공통 안내 배너로 보여준다.
//
//  ⚠️ "휴지통 열기" 버튼을 두지 말 것. `~/.Trash`는 TCC 보호 폴더라 샌드박스 앱이
//     `NSWorkspace.open`으로 열면 Finder가 "'휴지통'을 열 수 있는 권한이 없습니다"
//     시스템 경고를 띄운다(홈 폴더 권한이 있어도 동일). 앱에서 막을 수 없으므로
//     Dock의 휴지통을 쓰도록 문구로만 안내한다.
//
//  ⚠️ 앱이 휴지통을 직접 비우지는 않는다. 되돌릴 수 없는 삭제는 "복원 가능한 휴지통
//     이동만 한다"는 앱의 안전 원칙과 맞지 않고, Finder에 비우기를 시키려면
//     Apple Events 권한이 필요해 심사 위험이 있다.
//

import SwiftUI
import Combine

@MainActor
final class TrashReminder: ObservableObject {
    static let shared = TrashReminder()

    /// 배너를 닫은 뒤 새로 휴지통으로 옮긴 항목 수
    @Published private(set) var movedCount: Int = 0

    private init() {}

    /// `TrashService`가 휴지통 이동에 성공할 때마다 호출한다.
    func recordMoved(_ count: Int) {
        guard count > 0 else { return }
        movedCount += count
    }

    func dismiss() {
        movedCount = 0
    }
}

/// 화면 상단에 붙는 휴지통 안내 배너. 옮긴 항목이 없으면 아무것도 그리지 않는다.
struct TrashReminderBanner: View {
    @ObservedObject private var reminder = TrashReminder.shared

    var body: some View {
        if reminder.movedCount > 0 {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .foregroundStyle(Color.accentColor)
                Text("trash.reminder.message".localized(with: reminder.movedCount))
                    .appFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    reminder.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("common.close".localized)
                .accessibilityLabel(Text("common.close".localized))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
