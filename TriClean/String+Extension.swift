//
//  String+Extension.swift
//  TriClean
//
//  Created by nicechann on 1/26/26.
//

import Foundation
import os

// ⚠️ `nonisolated`: 이 프로젝트는 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`라
//   전역 `let`도 MainActor로 추론된다. `.localized`를 백그라운드에서 쓸 수 있게
//   하려면 이 로거부터 격리를 풀어야 한다. `Logger`는 Sendable이라 안전하다.
private nonisolated let localizationLogger = Logger(subsystem: "com.nicechann.TriClean", category: "Localization")

extension String {
    /// "key".localized 형태로 사용 (간단한 문자열)
    ///
    /// ⚠️ NSLocalizedString은 키를 찾지 못하면 **키 문자열 자체를 반환**한다.
    ///   지원 언어가 늘어날수록 번역 한 줄 누락이 곧바로
    ///   `junk.progress.cleaning` 같은 원본 노출로 이어지므로,
    ///   영어(en)로 폴백한 뒤 그래도 없을 때만 키를 반환한다.
    nonisolated var localized: String {
        let translated = NSLocalizedString(self, comment: "")
        if translated != self { return translated }

        if let fallback = Self.englishFallback(for: self) {
            #if DEBUG
            localizationLogger.warning("번역 누락 → 영어로 폴백: \(self, privacy: .public)")
            #endif
            return fallback
        }

        #if DEBUG
        localizationLogger.error("정의되지 않은 로컬라이즈 키: \(self, privacy: .public)")
        #endif
        return self
    }

    /// "key".localized(with: "값") 형태로 사용 (변수가 들어가는 문자열)
    nonisolated func localized(with arguments: CVarArg...) -> String {
        return String(format: self.localized, arguments: arguments)
    }

    // MARK: - 영어 폴백

    /// ⚠️ `nonisolated`가 필요한 이유: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 때문에
    ///   `static let`도 MainActor로 추론되는데, 이 값을 읽는 `englishFallback`은 nonisolated다.
    ///   `Bundle`은 `Sendable`이라 `unsafe` 없이 `nonisolated`만으로 충분하다.
    private nonisolated static let englishBundle: Bundle? = {
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    private nonisolated static func englishFallback(for key: String) -> String? {
        guard let bundle = englishBundle else { return nil }
        let value = bundle.localizedString(forKey: key, value: key, table: nil)
        return value == key ? nil : value
    }
}
