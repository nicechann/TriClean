//
//  TrialManager.swift
//  TriClean
//
//  Created by Assistant on 2/7/26.
//
//  ✅ [수정 v3]
//   - 키체인 저장 실패 시 매 실행마다 firstLaunchDate가 now로 리셋되어
//     체험 기간이 무한히 갱신되던 문제를 차단.
//   - 저장 실패 시 UserDefaults에 sentinel을 기록해, "이미 trial을 시작했으나
//     키체인에 영구화하지 못한 사용자"를 식별하고 더 이상의 trial을 부여하지 않음.
//     (정상 키체인 사용자는 UserDefaults sentinel을 무시합니다)
//
//  v2 변경 사항(유지):
//   - daysRemaining 초기값 7 → 0
//   - refresh()를 동기 호출로 변경하고 @MainActor 적용
//   - 시간 조작 검출 임계값 ±6h (시차/DST 보호)
//

import Foundation
import Combine
import os
import Security

// 날짜 데이터를 구조체로 관리
struct TrialData: Codable {
    let firstLaunchDate: Date
    var lastLaunchDate: Date
}

private let trialLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.nicechann.TriClean",
    category: "Trial"
)

@MainActor
final class TrialManager: ObservableObject {
    static let shared = TrialManager()

    private let trialDays: Double = 7
    private let keychainService = "com.triclean.service"
    private let keychainAccount = "trialData"

    // ✅ 키체인 저장에 실패해 trial 시작 시각을 영구화하지 못한 경우의 fallback 표식.
    //    한 번이라도 이 키가 true가 되면, 이후 키체인 데이터가 없더라도 trial은 0일로 간주합니다.
    private let trialStartedFallbackKey = "TriClean.trialStarted.fallback"

    // ✅ 시간 조작 허용 오차 — 시차/DST 변경으로 인한 정상 사용자 오인 방지
    private let clockSkewTolerance: TimeInterval = 6 * 3600  // 6시간

    // ✅ [수정] 만료 안전 기본값 (0). init에서 동기적으로 실제 값으로 갱신됨.
    @Published var daysRemaining: Int = 0

    var isTrialExpired: Bool {
        return daysRemaining <= 0
    }

    init() {
        // ✅ @MainActor 격리 → @StateObject 생성 시 메인에서 동기 실행됨.
        //   첫 body 평가 전에 정확한 값이 세팅되므로 깜빡임 race 없음.
        daysRemaining = calculateDaysRemaining()
    }

    /// 외부에서 갱신을 요청할 때 사용 (예: scenePhase가 .active로 전환).
    func refresh() {
        daysRemaining = calculateDaysRemaining()
    }

    // ✅ 내부 계산 로직 (값 변경 없이 계산 결과만 반환)
    private func calculateDaysRemaining() -> Int {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.trialDaysOverrideEnabled") {
            return UserDefaults.standard.integer(forKey: "debug.trialDaysOverride")
        }
        #endif

        let now = Date()

        // 1. 키체인에서 데이터 로드
        guard let data = KeychainHelper.shared.read(service: keychainService, account: keychainAccount),
              var trialData = try? JSONDecoder().decode(TrialData.self, from: data) else {

            // ✅ 키체인에 trial 데이터가 없는 경우:
            //   (a) 진짜 최초 실행 → 신규 trial 부여.
            //   (b) 과거에 키체인 저장이 실패했던 사용자 → fallback sentinel 확인 후 0일 반환.
            if UserDefaults.standard.bool(forKey: trialStartedFallbackKey) {
                trialLogger.warning("Trial keychain missing but fallback sentinel set — treating as expired.")
                return 0
            }

            let newData = TrialData(firstLaunchDate: now, lastLaunchDate: now)
            let status = save(newData)

            if status != errSecSuccess {
                // 키체인 저장에 실패했으므로, fallback sentinel을 기록해 둠.
                // 이렇게 하면 다음 실행 시 또다시 7일을 받지 못함.
                UserDefaults.standard.set(true, forKey: trialStartedFallbackKey)
                UserDefaults.standard.set(now.timeIntervalSince1970,
                                          forKey: "\(trialStartedFallbackKey).startedAt")
                trialLogger.warning("Trial keychain save failed (status=\(status, privacy: .public)) — using UserDefaults fallback.")
            }

            return Int(trialDays)
        }

        // 2. 🚨 시간 조작 감지 (Time Travel Protection)
        // (a) firstLaunchDate가 미래 → 키체인 변조로 체험 기간 무기한 연장 시도
        if trialData.firstLaunchDate > now.addingTimeInterval(clockSkewTolerance) {
            trialLogger.warning("Time manipulation detected: firstLaunchDate is in the future. now=\(Int(now.timeIntervalSince1970), privacy: .private), firstLaunch=\(Int(trialData.firstLaunchDate.timeIntervalSince1970), privacy: .private)")
            return 0
        }
        // (b) firstLaunchDate > lastLaunchDate → 논리적으로 불가능한 상태
        if trialData.firstLaunchDate > trialData.lastLaunchDate.addingTimeInterval(clockSkewTolerance) {
            trialLogger.warning("Time manipulation detected: firstLaunchDate is after lastLaunchDate. firstLaunch=\(Int(trialData.firstLaunchDate.timeIntervalSince1970), privacy: .private), lastLaunch=\(Int(trialData.lastLaunchDate.timeIntervalSince1970), privacy: .private)")
            return 0
        }
        // (c) 마지막 실행 시간보다 현재 시간이 6시간 이상 과거 → 시계 역행 조작
        if now < trialData.lastLaunchDate.addingTimeInterval(-clockSkewTolerance) {
            trialLogger.warning("Time manipulation detected: system clock moved backwards. now=\(Int(now.timeIntervalSince1970), privacy: .private), lastLaunch=\(Int(trialData.lastLaunchDate.timeIntervalSince1970), privacy: .private)")
            return 0
        }

        // 3. 마지막 실행 시간 갱신 (현재 시간이 더 미래일 때만)
        if now > trialData.lastLaunchDate {
            trialData.lastLaunchDate = now
            _ = save(trialData)
            // 여기서 저장 실패해도 다음 실행 때 다시 시도되므로 fallback sentinel은 건드리지 않음.
        }

        // 4. 남은 기간 계산
        //    fallback sentinel에 기록된 startedAt이 있다면(예외적 케이스),
        //    키체인 데이터와 비교해 더 이른 시각을 채택해 우회를 막습니다.
        let effectiveFirstLaunch: Date = {
            guard UserDefaults.standard.bool(forKey: trialStartedFallbackKey) else {
                return trialData.firstLaunchDate
            }
            let fallbackStart = UserDefaults.standard.double(forKey: "\(trialStartedFallbackKey).startedAt")
            guard fallbackStart > 0 else { return trialData.firstLaunchDate }
            let fallbackDate = Date(timeIntervalSince1970: fallbackStart)
            return min(trialData.firstLaunchDate, fallbackDate)
        }()

        let elapsed = now.timeIntervalSince(effectiveFirstLaunch)
        let daysPassed = elapsed / (24 * 60 * 60)
        let remaining = Int(ceil(trialDays - daysPassed))

        return max(remaining, 0)
    }

    #if DEBUG
    /// DEBUG 전용: 체험 기간 남은 일수를 강제 설정합니다. 앱 재시작 후에도 유지됩니다.
    func debugSetDaysRemaining(_ days: Int) {
        UserDefaults.standard.set(true, forKey: "debug.trialDaysOverrideEnabled")
        UserDefaults.standard.set(days, forKey: "debug.trialDaysOverride")
        daysRemaining = days
    }

    /// DEBUG 전용: 강제 설정된 체험 기간을 해제하고 실제 키체인 값으로 되돌립니다.
    func debugResetTrialOverride() {
        UserDefaults.standard.removeObject(forKey: "debug.trialDaysOverrideEnabled")
        UserDefaults.standard.removeObject(forKey: "debug.trialDaysOverride")
        refresh()
    }
    #endif

    @discardableResult
    private func save(_ data: TrialData) -> OSStatus {
        guard let encoded = try? JSONEncoder().encode(data) else {
            trialLogger.error("Trial data encoding failed.")
            return errSecParam
        }
        return KeychainHelper.shared.save(encoded, service: keychainService, account: keychainAccount)
    }
}
