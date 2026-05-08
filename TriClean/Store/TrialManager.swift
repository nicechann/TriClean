//
//  TrialManager.swift
//  TriClean
//
//  Created by Assistant on 2/7/26.
//
//  ✅ [수정 v2]
//   - daysRemaining 초기값 7 → 0 (만료 안전 기본값). 첫 프레임에서 만료된 사용자가
//     ContentView를 잠깐 보던 race condition 제거.
//   - refresh()를 동기 호출로 변경하고 @MainActor를 적용해 SwiftUI 격리와 일치.
//   - 시간 조작 검출 임계값을 ±1h → ±6h로 완화 (시차/일광절약 등 정상 사용자 보호).
//

import Foundation
import Combine

// 날짜 데이터를 구조체로 관리
struct TrialData: Codable {
    let firstLaunchDate: Date
    var lastLaunchDate: Date
}

@MainActor
final class TrialManager: ObservableObject {
    static let shared = TrialManager()

    private let trialDays: Double = 7
    private let keychainService = "com.triclean.service"
    private let keychainAccount = "trialData"

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

            // 데이터 없음 -> 최초 실행으로 간주
            let newData = TrialData(firstLaunchDate: now, lastLaunchDate: now)
            save(newData)
            return Int(trialDays)
        }

        // 2. 🚨 시간 조작 감지 (Time Travel Protection)
        // (a) firstLaunchDate가 미래 → 키체인 변조로 체험 기간 무기한 연장 시도
        if trialData.firstLaunchDate > now.addingTimeInterval(clockSkewTolerance) {
            print("Time manipulation detected! firstLaunchDate is in the future.")
            return 0
        }
        // (b) firstLaunchDate > lastLaunchDate → 논리적으로 불가능한 상태
        if trialData.firstLaunchDate > trialData.lastLaunchDate.addingTimeInterval(clockSkewTolerance) {
            print("Time manipulation detected! firstLaunchDate is after lastLaunchDate.")
            return 0
        }
        // (c) 마지막 실행 시간보다 현재 시간이 6시간 이상 과거 → 시계 역행 조작
        if now < trialData.lastLaunchDate.addingTimeInterval(-clockSkewTolerance) {
            print("Time manipulation detected! System clock moved backwards.")
            return 0
        }

        // 3. 마지막 실행 시간 갱신 (현재 시간이 더 미래일 때만)
        if now > trialData.lastLaunchDate {
            trialData.lastLaunchDate = now
            save(trialData)
        }

        // 4. 남은 기간 계산
        let elapsed = now.timeIntervalSince(trialData.firstLaunchDate)
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

    private func save(_ data: TrialData) {
        if let encoded = try? JSONEncoder().encode(data) {
            KeychainHelper.shared.save(encoded, service: keychainService, account: keychainAccount)
        }
    }
}
