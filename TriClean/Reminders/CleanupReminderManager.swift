//
//  CleanupReminderManager.swift
//  TriClean
//
//  주간 정리 리마인더 (매주 고정 요일·시간 반복)
//
//  설계 노트:
//  - 로컬 알림은 샌드박스 MAS 앱에서 별도 entitlement가 필요 없습니다.
//    (aps-environment는 '원격 푸시' 전용) 현재 TriClean.entitlements 그대로 동작합니다.
//  - 권한은 앱 첫 실행이 아니라 "설정에서 토글을 켤 때" 요청합니다(거부율↓).
//  - 예약은 UNCalendarNotificationTrigger(repeats: true)로 매주 같은 요일·시간에 반복.
//  - 고정 식별자(requestID)로 add하므로, 재예약 시 기존 예약을 덮어써 중복 누적이 없습니다.
//  - 다른 매니저(StoreManager/TrialManager/KeychainHelper)와 동일하게
//    @MainActor + .shared 싱글톤 + os.Logger 패턴을 따릅니다.
//

import Foundation
import Combine
import UserNotifications
import AppKit
import os.log

@MainActor
final class CleanupReminderManager: ObservableObject {

    static let shared = CleanupReminderManager()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.nicechann.TriClean",
        category: "Reminder"
    )

    private let center = UNUserNotificationCenter.current()

    /// 고정 식별자 — 재예약 시 기존 요청을 교체(덮어쓰기)해 중복 알림을 방지합니다.
    private let requestID = "com.triclean.reminder.weekly"

    // MARK: - 저장 키 (UserDefaults / @AppStorage와 동일 저장소)

    private let enabledKey = "TriClean.reminder.enabled"
    private let weekdayKey = "TriClean.reminder.weekday"   // 1=일 ... 7=토 (DateComponents.weekday 규약)
    private let hourKey    = "TriClean.reminder.hour"
    private let minuteKey  = "TriClean.reminder.minute"

    // MARK: - Published 설정 상태

    /// 리마인더 사용 여부. 토글 시 권한 요청/예약 또는 예약 해제를 수행합니다.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
            if isEnabled {
                Task { await enable() }
            } else {
                disable()
            }
        }
    }

    /// 알림 요일 (1=일요일 ... 7=토요일). Calendar/DateComponents 규약과 동일.
    @Published var weekday: Int {
        didSet {
            guard oldValue != weekday else { return }
            UserDefaults.standard.set(weekday, forKey: weekdayKey)
            rescheduleIfEnabled()
        }
    }

    /// 알림 시(0...23)
    @Published var hour: Int {
        didSet {
            guard oldValue != hour else { return }
            UserDefaults.standard.set(hour, forKey: hourKey)
            rescheduleIfEnabled()
        }
    }

    /// 알림 분(0...59)
    @Published var minute: Int {
        didSet {
            guard oldValue != minute else { return }
            UserDefaults.standard.set(minute, forKey: minuteKey)
            rescheduleIfEnabled()
        }
    }

    /// 현재 시스템 알림 권한 상태 (UI에서 '거부됨' 안내에 사용).
    @Published private(set) var authStatus: UNAuthorizationStatus = .notDetermined

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        isEnabled = defaults.bool(forKey: enabledKey)

        // 기본값: 토요일(7) 오전 10:00 — 주말 오전에 가볍게 정리 유도
        let storedWeekday = defaults.integer(forKey: weekdayKey)
        weekday = (1...7).contains(storedWeekday) ? storedWeekday : 7

        // hour 기본 10, minute 기본 0. (integer(forKey:)는 미설정 시 0을 반환하므로 존재 여부로 구분)
        hour = defaults.object(forKey: hourKey) != nil ? defaults.integer(forKey: hourKey) : 10
        minute = defaults.object(forKey: minuteKey) != nil ? defaults.integer(forKey: minuteKey) : 0

        Task {
            await refreshAuthStatus()
            // 활성 상태로 저장돼 있고 권한이 있으면, 앱 실행 시 예약을 보정.
            rescheduleIfEnabled()
        }
    }

    // MARK: - 외부 진입점

    /// 앱 활성화(scenePhase == .active) 또는 설정 화면 진입 시 호출.
    /// 사용자가 시스템 설정에서 권한을 바꿨을 수 있으므로 상태를 갱신하고 예약을 보정합니다.
    func refreshSchedule() {
        Task {
            await refreshAuthStatus()
            rescheduleIfEnabled()
        }
    }

    /// 시스템 알림 설정 화면 열기 (권한이 거부된 경우 안내용).
    func openSystemNotificationSettings() {
        // macOS 13+ 알림 설정 pane. 만약 정확히 안 열리면 아래 일반 URL로 폴백됩니다.
        let paneURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        let fallbackURL = URL(string: "x-apple.systempreferences:")
        if let paneURL {
            NSWorkspace.shared.open(paneURL)
        } else if let fallbackURL {
            NSWorkspace.shared.open(fallbackURL)
        }
    }

    // MARK: - 내부 구현

    private func rescheduleIfEnabled() {
        guard isEnabled else { return }
        Task { await schedule() }
    }

    private func enable() async {
        let granted = await requestAuthorizationIfNeeded()
        await refreshAuthStatus()

        // 권한이 거부돼도 예약 자체는 무해합니다(전달만 안 됨). 사용자가 이후
        // 시스템 설정에서 허용하면 다음 실행 시 refreshSchedule로 이어집니다.
        await schedule()

        if !granted {
            logger.notice("Reminder enabled but notification authorization not granted (status=\(self.authStatus.rawValue, privacy: .public)).")
        }
    }

    private func disable() {
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        logger.notice("Weekly cleanup reminder cancelled.")
    }

    private func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                logger.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        @unknown default:
            return false
        }
    }

    private func refreshAuthStatus() async {
        let settings = await center.notificationSettings()
        authStatus = settings.authorizationStatus
    }

    private func schedule() async {
        // 기존 예약 제거 후 재등록(고정 requestID라 사실상 교체지만 명시적으로 정리).
        center.removePendingNotificationRequests(withIdentifiers: [requestID])

        var components = DateComponents()
        components.weekday = weekday       // 1=일 ... 7=토
        components.hour = hour
        components.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        let content = UNMutableNotificationContent()
        content.title = "reminder.notification.title".localized
        content.body = "reminder.notification.body".localized
        content.sound = .default

        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)

        do {
            try await center.add(request)
            logger.notice("Weekly cleanup reminder scheduled (weekday=\(self.weekday, privacy: .public) \(self.hour, privacy: .public):\(self.minute, privacy: .public)).")
        } catch {
            logger.error("Failed to schedule reminder: \(error.localizedDescription, privacy: .public)")
        }
    }
}
