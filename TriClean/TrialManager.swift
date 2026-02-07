//
//  TrialManager.swift
//  TriClean
//
//  Created by Assistant on 2/7/26.
//

import Foundation
import Combine

final class TrialManager: ObservableObject {
    static let shared = TrialManager()
    
    private let firstLaunchKey = "TriClean.FirstLaunchDate"
    private let trialDays: Double = 7
    private let keychainService = "com.triclean.service"
    private let keychainAccount = "firstLaunchDate"

    var daysRemaining: Int {
        // 1. 키체인에서 날짜 로드 시도
        if let data = KeychainHelper.shared.read(service: keychainService, account: keychainAccount),
           let date = try? JSONDecoder().decode(Date.self, from: data) {
            
            let elapsed = Date().timeIntervalSince(date)
            let daysPassed = elapsed / (24 * 60 * 60)
            return max(Int(ceil(trialDays - daysPassed)), 0)
        } 
        
        // 2. 키체인에 없으면 새로 저장 (첫 실행)
        let now = Date()
        if let data = try? JSONEncoder().encode(now) {
            KeychainHelper.shared.save(data, service: keychainService, account: keychainAccount)
        }
        return Int(trialDays)
    }
    
    var isTrialExpired: Bool {
        return daysRemaining <= 0
    }
}
