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
//  - 같은 활성화 주기에는 고정 식별자로 add해 기존 예약을 교체하고,
//    OFF → ON 시에는 새 식별자로 회전해 비동기 삭제와 신규 예약의 경쟁 조건을 방지합니다.
//  - 다른 매니저(StoreManager/TrialManager/KeychainHelper)와 동일하게
//    @MainActor + .shared 싱글톤 + os.Logger 패턴을 따릅니다.
//

import Foundation
import Combine
import UserNotifications
import AppKit
import os.log

/// 앱이 전면에 있을 때도 주간 정리 알림을 배너와 사운드로 표시합니다.
private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
final class CleanupReminderManager: ObservableObject {

    static let shared = CleanupReminderManager()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.nicechann.TriClean",
        category: "Reminder"
    )

    private let center = UNUserNotificationCenter.current()
    private let notificationDelegate = ForegroundNotificationDelegate()

    /// 이전 버전과의 호환 및 알림 요청 식별자 접두사.
    private let requestIdentifierPrefix = "com.triclean.reminder.weekly"
    private let requestIdentifierKey = "TriClean.reminder.requestIdentifier"

    /// 같은 활성화 주기에는 동일 식별자를 사용해 재예약 시 기존 요청을 교체합니다.
    private var requestIdentifier = "com.triclean.reminder.weekly"

    /// 권한 요청·예약·해제 흐름이 겹치지 않도록 마지막 작업만 유지합니다.
    private var operationTask: Task<Void, Never>?

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
                let identifier = rotateRequestIdentifier()
                startEnableFlow(for: identifier)
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
        requestIdentifier = defaults.string(forKey: requestIdentifierKey) ?? requestIdentifierPrefix

        // 기본값: 토요일(7) 오전 10:00 — 주말 오전에 가볍게 정리 유도
        let storedWeekday = defaults.integer(forKey: weekdayKey)
        weekday = (1...7).contains(storedWeekday) ? storedWeekday : 7

        // hour 기본 10, minute 기본 0. (integer(forKey:)는 미설정 시 0을 반환하므로 존재 여부로 구분)
        hour = defaults.object(forKey: hourKey) != nil ? defaults.integer(forKey: hourKey) : 10
        minute = defaults.object(forKey: minuteKey) != nil ? defaults.integer(forKey: minuteKey) : 0

        // delegate는 weak 참조이므로 프로퍼티로 보관해 앱 생명주기 동안 유지합니다.
        center.delegate = notificationDelegate

        if isEnabled {
            refreshSchedule()
        } else {
            // 이전 실행에서 해제 작업이 완료되기 전에 앱이 종료된 경우를 보정합니다.
            removePendingRequests(withIdentifiers: [requestIdentifier, requestIdentifierPrefix])
        }
    }

    // MARK: - 외부 진입점

    /// 앱 활성화(scenePhase == .active) 또는 설정 화면 진입 시 호출.
    /// 사용자가 시스템 설정에서 권한을 바꿨을 수 있으므로 상태를 갱신하고 예약을 보정합니다.
    func refreshSchedule() {
        operationTask?.cancel()
        let identifier = requestIdentifier

        operationTask = Task {
            await refreshAuthStatus()

            guard !Task.isCancelled,
                  isEnabled,
                  requestIdentifier == identifier,
                  canScheduleNotifications else {
                return
            }

            await schedule(identifier: identifier)
        }
    }

    /// 시스템 알림 설정 화면 열기 (권한이 거부된 경우 안내용).
    func openSystemNotificationSettings() {
        // macOS 13+ 알림 설정 pane. 열기에 실패하면 시스템 설정 일반 화면으로 폴백합니다.
        if let paneURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
           NSWorkspace.shared.open(paneURL) {
            return
        }

        if let fallbackURL = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(fallbackURL)
        }
    }

    // MARK: - 내부 구현

    private var canScheduleNotifications: Bool {
        authStatus == .authorized || authStatus == .provisional
    }

    /// OFF → ON 전환 시 새 식별자를 사용합니다.
    /// 이전 식별자 삭제가 늦게 완료돼도 신규 예약에는 영향을 주지 않습니다.
    @discardableResult
    private func rotateRequestIdentifier() -> String {
        let previousIdentifier = requestIdentifier
        let newIdentifier = "\(requestIdentifierPrefix).\(UUID().uuidString)"

        requestIdentifier = newIdentifier
        UserDefaults.standard.set(newIdentifier, forKey: requestIdentifierKey)

        removePendingRequests(withIdentifiers: [previousIdentifier, requestIdentifierPrefix])
        return newIdentifier
    }

    private func startEnableFlow(for identifier: String) {
        operationTask?.cancel()
        operationTask = Task {
            let granted = await requestAuthorizationIfNeeded()
            await refreshAuthStatus()

            guard !Task.isCancelled,
                  isEnabled,
                  requestIdentifier == identifier else {
                return
            }

            guard granted, canScheduleNotifications else {
                logger.notice("Reminder enabled but notification authorization not granted (status=\(self.authStatus.rawValue, privacy: .public)).")
                return
            }

            await schedule(identifier: identifier)
        }
    }

    /// DatePicker가 시·분 값을 연속 갱신하므로 짧게 디바운스해 최종 값만 예약합니다.
    private func rescheduleIfEnabled() {
        guard isEnabled else { return }

        operationTask?.cancel()
        let identifier = requestIdentifier

        operationTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }

            await refreshAuthStatus()

            guard !Task.isCancelled,
                  isEnabled,
                  requestIdentifier == identifier,
                  canScheduleNotifications else {
                return
            }

            await schedule(identifier: identifier)
        }
    }

    private func disable() {
        operationTask?.cancel()
        operationTask = nil

        removePendingRequests(withIdentifiers: [requestIdentifier, requestIdentifierPrefix])
        logger.notice("Weekly cleanup reminder cancelled.")
    }

    private func removePendingRequests(withIdentifiers identifiers: [String]) {
        let uniqueIdentifiers = Array(Set(identifiers))
        center.removePendingNotificationRequests(withIdentifiers: uniqueIdentifiers)
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

    private func schedule(identifier: String) async {
        guard canScheduleNotifications else { return }

        var components = DateComponents()
        components.weekday = weekday       // 1=일 ... 7=토
        components.hour = hour
        components.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        let content = UNMutableNotificationContent()
        content.title = "reminder.notification.title".localized
        content.body = "reminder.notification.body".localized
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await center.add(request)

            // 권한 요청 또는 add 도중 사용자가 토글을 끄거나 다시 켠 경우 잔여 예약을 제거합니다.
            guard isEnabled,
                  requestIdentifier == identifier else {
                removePendingRequests(withIdentifiers: [identifier])
                return
            }

            logger.notice("Weekly cleanup reminder scheduled (weekday=\(self.weekday, privacy: .public) \(self.hour, privacy: .public):\(self.minute, privacy: .public)).")
        } catch is CancellationError {
            if !isEnabled || requestIdentifier != identifier {
                removePendingRequests(withIdentifiers: [identifier])
            }
        } catch {
            logger.error("Failed to schedule reminder: \(error.localizedDescription, privacy: .public)")
        }
    }
}
