//
//  DuplicateCSVExporterTests.swift
//  TriCleanTests
//

import XCTest
@testable import TriClean

final class DuplicateCSVExporterTests: XCTestCase {
    func test_CSV는_UTF8_BOM과_헤더를_포함한다() throws {
        let data = DuplicateCSVExporter.makeData(groups: [makeGroup()])

        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])

        let body = try XCTUnwrap(String(data: data.dropFirst(3), encoding: .utf8))
        XCTAssertTrue(body.hasPrefix("\"Group\",\"SHA-256\",\"File Name\",\"Full Path\""))
        XCTAssertTrue(body.contains("\"Keep\""))
        XCTAssertTrue(body.contains("\"Delete\""))
    }

    func test_CSV는_쉼표와_따옴표를_올바르게_이스케이프한다() throws {
        let file = DuplicateFile(
            url: URL(fileURLWithPath: "/tmp/root/report, \"copy\".pdf"),
            modificationDate: nil,
            isKeep: true
        )
        let group = DuplicateGroup(hash: "abc123", fileSize: 100, files: [file])

        let body = try csvBody(groups: [group])
        XCTAssertTrue(body.contains("\"report, \"\"copy\"\".pdf\""))
    }

    func test_CSV는_스프레드시트_수식_주입을_차단한다() throws {
        let file = DuplicateFile(
            url: URL(fileURLWithPath: "/tmp/root/=SUM(1,1).csv"),
            modificationDate: nil,
            isKeep: true
        )
        let group = DuplicateGroup(hash: "abc123", fileSize: 100, files: [file])

        let body = try csvBody(groups: [group])
        XCTAssertTrue(body.contains("\"'=SUM(1,1).csv\""))
    }

    private func makeGroup() -> DuplicateGroup {
        DuplicateGroup(
            hash: "abc123",
            fileSize: 1_024,
            files: [
                DuplicateFile(
                    url: URL(fileURLWithPath: "/tmp/root/original.txt"),
                    modificationDate: Date(timeIntervalSince1970: 0),
                    isKeep: true
                ),
                DuplicateFile(
                    url: URL(fileURLWithPath: "/tmp/root/copy.txt"),
                    modificationDate: Date(timeIntervalSince1970: 1),
                    isKeep: false
                )
            ]
        )
    }

    private func csvBody(groups: [DuplicateGroup]) throws -> String {
        let data = DuplicateCSVExporter.makeData(groups: groups)
        return try XCTUnwrap(String(data: data.dropFirst(3), encoding: .utf8))
    }
}
