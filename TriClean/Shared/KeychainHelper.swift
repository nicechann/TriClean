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
//   - 키체인 조회 오류와 실제 미존재를 구분해 신규 체험판 오발급을 방지.
//

import Security
import Foundation
import os.log

private let keychainLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.nicechann.TriClean",
    category: "Keychain"
)

enum KeychainReadResult {
    case found(Data)
    case notFound
    case failed(OSStatus)
}

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
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            // ✅ macOS에서 kSecAttrAccessible / kSecAttrSynchronizable은
            //    데이터 보호 키체인에서만 유효하다. 이 플래그가 없으면 레거시
            //    파일 기반 키체인으로 라우팅되어 두 속성이 무시될 수 있고,
            //    SecItemUpdate에 kSecAttrAccessible을 넘기면 errSecParam이 날 수 있다.
            kSecUseDataProtectionKeychain: true
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

    /// 데이터 보호 키체인을 먼저 조회하고, 없을 때만 레거시 키체인을 확인합니다.
    /// 조회 오류는 `notFound`와 구분해 호출자가 신규 데이터로 오판하지 않게 합니다.
    func readResult(service: String, account: String) -> KeychainReadResult {
        switch readItem(service: service, account: account, dataProtection: true) {
        case .found(let data):
            return .found(data)
        case .failed(let status):
            return .failed(status)
        case .notFound:
            break
        }

        switch readItem(service: service, account: account, dataProtection: false) {
        case .found(let legacy):
            let status = save(legacy, service: service, account: account)
            if status != errSecSuccess {
                keychainLogger.error(
                    "Keychain migration failed status=\(status, privacy: .public) service=\(service, privacy: .private) account=\(account, privacy: .private)"
                )
            }
            return .found(legacy)
        case .notFound:
            return .notFound
        case .failed(let status):
            return .failed(status)
        }
    }

    /// 기존 호출부 호환용. 신규 보안 로직은 `readResult`를 사용해야 합니다.
    func read(service: String, account: String) -> Data? {
        guard case .found(let data) = readResult(service: service, account: account) else {
            return nil
        }
        return data
    }

    private func readItem(
        service: String,
        account: String,
        dataProtection: Bool
    ) -> KeychainReadResult {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain] = true
        }

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        switch status {
        case errSecSuccess:
            guard let data = dataTypeRef as? Data else {
                keychainLogger.error(
                    "Keychain read returned unexpected type service=\(service, privacy: .private) account=\(account, privacy: .private)"
                )
                return .failed(errSecDecode)
            }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            keychainLogger.error(
                "Keychain read failed status=\(status, privacy: .public) service=\(service, privacy: .private) account=\(account, privacy: .private)"
            )
            return .failed(status)
        }
    }

}
