//
//  DuplicateCSVExporter.swift
//  TriClean
//
//  중복 파일 스캔 결과를 Excel 등에서 안전하게 열 수 있는 CSV로 직렬화합니다.
//

import Foundation

nonisolated enum DuplicateCSVExporter {
    private static let headers = [
        "Group",
        "SHA-256",
        "File Name",
        "Full Path",
        "Parent Folder",
        "Size (Bytes)",
        "Size (Formatted)",
        "Modified Date",
        "Action",
        "Duplicate Count",
        "Group Reclaimable Bytes"
    ]

    /// UTF-8 BOM을 포함한 CSV 데이터입니다.
    /// BOM은 Excel에서 다국어 파일명을 UTF-8로 안정적으로 인식하도록 돕습니다.
    static func makeData(groups: [DuplicateGroup]) -> Data {
        var lines: [String] = []
        lines.reserveCapacity(1 + groups.reduce(0) { $0 + $1.files.count })
        lines.append(headers.map(csvField).joined(separator: ","))

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for (groupIndex, group) in groups.enumerated() {
            for file in group.files {
                let modifiedDate = file.modificationDate.map(dateFormatter.string(from:)) ?? ""
                let row = [
                    String(groupIndex + 1),
                    group.hash,
                    spreadsheetSafeText(file.name),
                    spreadsheetSafeText(file.path),
                    spreadsheetSafeText(file.parentFolder),
                    String(group.fileSize),
                    group.fileSizeString,
                    modifiedDate,
                    file.isKeep ? "Keep" : "Delete",
                    String(group.duplicateCount),
                    String(group.reclaimableBytes)
                ]
                lines.append(row.map(csvField).joined(separator: ","))
            }
        }

        let csv = lines.joined(separator: "\r\n") + "\r\n"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(csv.data(using: .utf8) ?? Data())
        return data
    }

    /// Excel/Numbers에서 파일명 같은 외부 입력이 수식으로 실행되지 않도록 보호합니다.
    /// 따옴표로 감싸는 것만으로는 스프레드시트 수식 실행을 막을 수 없으므로,
    /// 첫 유효 문자가 =, +, -, @ 인 텍스트에는 작은따옴표를 앞에 붙입니다.
    private static func spreadsheetSafeText(_ value: String) -> String {
        let trimmedLeading = value.drop { character in
            character == " " || character == "\t" || character == "\r" || character == "\n"
        }
        guard let first = trimmedLeading.first, "=+-@".contains(first) else {
            return value
        }
        return "'" + value
    }

    /// RFC 4180 호환을 위해 모든 필드를 따옴표로 감싸고 내부 따옴표를 두 번 씁니다.
    private static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
