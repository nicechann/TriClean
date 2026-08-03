//
//  String+Extension.swift
//  TriClean
//
//  Created by nicechann on 1/26/26.
//

import Foundation

extension String {
    /// "key".localized 형태로 사용 (간단한 문자열)
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }

    /// "key".localized(with: "값") 형태로 사용 (변수가 들어가는 문자열)
    func localized(with arguments: CVarArg...) -> String {
        return String(format: self.localized, arguments: arguments)
    }
}
