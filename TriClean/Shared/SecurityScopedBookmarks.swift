//
//  SecurityScopedBookmarks.swift
//  TriClean
//
//  Created by changyu Kang on 17/12/2025.
//

import Foundation
import os.log

private let bookmarkLogger = Logger(subsystem: "com.nicechann.TriClean", category: "Bookmark")

/// 앱 전역 보안 스코프 북마크 키.
///
/// ⚠️ rawValue는 기존 사용자의 UserDefaults에 이미 저장된 키 문자열이다.
/// 값을 바꾸면 업데이트 시 사용자가 부여한 폴더 접근 권한이 전부 사라지므로
/// 절대 변경하지 말 것.
enum TriCleanBookmarkKey: String, CaseIterable {
    case junkLibraryFolder = "TriClean.JunkCleaner.LibraryBookmark"
    case duplicateScanFolder = "TriClean.DuplicateFinder.FolderBookmark"
    case photoScanFolder = "TriClean.PhotoManager.FolderBookmark"
    case appsApplicationsFolder = "TriClean.Apps.Bookmark.ApplicationsFolder"
    case appsUserLibraryFolder = "TriClean.Apps.Bookmark.UserLibraryFolder"
    case appsManualAppBundle = "TriClean.Apps.Bookmark.ManualAppBundle"

    var pathKey: String { rawValue + ".path" }
}

final class SecurityScopedBookmarkStore {
    static let shared = SecurityScopedBookmarkStore()
    private let defaults = UserDefaults.standard
    private init() {}

    func save(url: URL, for key: TriCleanBookmarkKey) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: key.rawValue)
        defaults.set(url.path, forKey: key.pathKey)
    }

    /// 저장 실패는 조용히 무시하지 않고 로그를 남긴다.
    /// (실패를 삼키면 사용자는 다음 실행 때 이유 없이 권한을 다시 요구받는다.)
    @discardableResult
    func trySave(url: URL, for key: TriCleanBookmarkKey) -> Bool {
        do {
            try save(url: url, for: key)
            return true
        } catch {
            bookmarkLogger.error(
                "북마크 저장 실패 key=\(key.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func resolveURL(for key: TriCleanBookmarkKey) -> URL? {
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale { trySave(url: url, for: key) }
            return url
        } catch {
            return nil
        }
    }

    func storedPath(for key: TriCleanBookmarkKey) -> String? {
        defaults.string(forKey: key.pathKey)
    }

    func clear(_ key: TriCleanBookmarkKey) {
        defaults.removeObject(forKey: key.rawValue)
        defaults.removeObject(forKey: key.pathKey)
    }
}

/// 보안 스코프 접근을 RAII로 관리합니다.
/// 내부 상태를 NSLock으로 보호하므로 여러 컨텍스트에서 stop()을 호출해도 안전합니다.
final class SecurityScopedAccessToken: @unchecked Sendable {
    private let url: URL
    private let didStart: Bool

    private let lock = NSLock()
    private var didStop = false

    init?(url: URL) {
        self.url = url
        self.didStart = url.startAccessingSecurityScopedResource()
        if !didStart { return nil }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard didStart, !didStop else { return }
        didStop = true
        url.stopAccessingSecurityScopedResource()
    }

    deinit {
        stop()
    }
}
