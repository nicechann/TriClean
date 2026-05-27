//
//  KeychainHelper.swift
//  TriClean
//
//  Created by nicechann on 2/7/26.
//
//  ✅ [수정 v4]
//   - 기존 항목을 먼저 삭제하지 않고 SecItemUpdate → SecItemAdd 순서로 저장.
//     저장 실패 시 기존 trial 데이터가 유실되어 체험판이 재부여되는 경로를 차단.
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
        // ✅ 기존 항목을 먼저 삭제하지 않습니다.
        //    delete → add 구조는 add 실패 시 기존 trial 데이터까지 사라져
        //    다음 실행에서 trial이 재부여될 수 있으므로 update → add 순서로 처리합니다.
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]

        let updateAttributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return updateStatus
        }

        guard updateStatus == errSecItemNotFound else {
            keychainLogger.error(
                "Keychain update failed status=\(updateStatus, privacy: .public) service=\(service, privacy: .private) account=\(account, privacy: .private)"
            )
            return updateStatus
        }

        // 신규 항목 추가
        // - kSecAttrAccessible: AfterFirstUnlock 으로 설정하여 로그인 직후부터 접근 가능하게 함.
        // - kSecAttrSynchronizable: false 로 명시하여 iCloud Keychain 동기화를 차단.
        var addQuery = query
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            // privacy 마커: 오류 코드는 민감 정보가 아니므로 public, account/service는 private.
            keychainLogger.error(
                "Keychain add failed status=\(addStatus, privacy: .public) service=\(service, privacy: .private) account=\(account, privacy: .private)"
            )
        }

        return addStatus
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
