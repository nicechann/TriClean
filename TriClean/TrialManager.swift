//
//  TrialManager.swift
//  TriClean
//
//  Created by Assistant on 2/7/26.
//

import Foundation
import Combine

// 날짜 데이터를 구조체로 관리
struct TrialData: Codable {
    let firstLaunchDate: Date
    var lastLaunchDate: Date
}

final class TrialManager: ObservableObject {
    static let shared = TrialManager()
    
    private let trialDays: Double = 7
    private let keychainService = "com.triclean.service"
    private let keychainAccount = "trialData"

    // ✅ [수정] 뷰가 읽을 때는 계산하지 않고 저장된 값을 즉시 반환 (기본값 7일)
    @Published var daysRemaining: Int = 7
    
    var isTrialExpired: Bool {
        return daysRemaining <= 0
    }

    init() {
        // 앱 시작 시 초기 계산 수행
        refresh()
    }

    // ✅ [수정] 외부(App)에서 호출하거나 초기화 시에만 값을 갱신
    func refresh() {
        // UI 업데이트는 메인 스레드에서 보장
        DispatchQueue.main.async {
            self.daysRemaining = self.calculateDaysRemaining()
        }
    }
    
    // ✅ [수정] 내부 계산 로직 (값 변경 없이 계산 결과만 반환)
    private func calculateDaysRemaining() -> Int {
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
        if trialData.firstLaunchDate > now.addingTimeInterval(3600) {
            print("Time manipulation detected! firstLaunchDate is in the future.")
            return 0
        }
        // (b) firstLaunchDate > lastLaunchDate → 논리적으로 불가능한 상태
        if trialData.firstLaunchDate > trialData.lastLaunchDate.addingTimeInterval(3600) {
            print("Time manipulation detected! firstLaunchDate is after lastLaunchDate.")
            return 0
        }
        // (c) 마지막 실행 시간보다 현재 시간이 1시간 이상 과거 → 시계 역행 조작
        if now < trialData.lastLaunchDate.addingTimeInterval(-3600) {
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
    
    private func save(_ data: TrialData) {
        if let encoded = try? JSONEncoder().encode(data) {
            KeychainHelper.shared.save(encoded, service: keychainService, account: keychainAccount)
        }
    }
}