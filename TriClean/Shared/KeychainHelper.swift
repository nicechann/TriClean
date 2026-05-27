//
//  KeychainHelper.swift
//  TriClean
//
//  Created by nicechann on 2/7/26.
//
//  ✅ [수정 v3]
//   - SecItemAdd 반환값(OSStatus)을 호출자에게 전달해 저장 실패를 감지 가능하도록 변경.
//   - kSecAttrAccessible 명시 (AfterFirstUnlock) — 백그라운드 접근 가능하면서 안전.
//   - kSecAttrSynchronizable=false 명시 — iCloud Keychain 동기화로 인한
//     "다른 Mac에서 trial 이어받기" 우회를 차단.
//   - read에서 typeMismatch가 발생할 때 OSStatus만으로는 구분할 수 없으므로 nil 반환.
//

import Security
import Foundation
import os.log

private let keychainLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.nicechann.TriClean",
    category: "Keychain"
)

final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    /// 저장 결과를 OSStatus로 반환합니다.
    /// - Returns: `errSecSuccess`(0)인 경우에만 키체인에 안전하게 저장되었음이 보장됩니다.
    @discardableResult
    func save(_ data: Data, service: String, account: String) -> OSStatus {
        // 1) 기존 항목 삭제 (중복 방지)
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        // 삭제 실패(errSecItemNotFound 포함)는 무시 — 신규 저장 시 정상 케이스이기도 함.
        SecItemDelete(deleteQuery as CFDictionary)

        // 2) 신규 항목 추가
        //    - kSecAttrAccessible: AfterFirstUnlock 으로 설정하여 로그인 직후부터 접근 가능하게 함.
        //    - kSecAttrSynchronizable: false 로 명시하여 iCloud Keychain 동기화를 차단.
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            // privacy 마커: 오류 코드는 민감 정보가 아니므로 public, account/service는 private.
            keychainLogger.error(
                "Keychain save failed status=\(status, privacy: .public) service=\(service, privacy: .private) account=\(account, privacy: .private)"
            )
        }
        return status
    }

    func read(service: String, account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        switch status {
        case errSecSuccess:
            return dataTypeRef as? Data
        case errSecItemNotFound:
            // 정상적인 "최초 실행" 케이스 — 로그 남기지 않음.
            return nil
        default:
            keychainLogger.error(
                "Keychain read failed status=\(status, privacy: .public) service=\(service, privacy: .private)"
            )
            return nil
        }
    }
}
