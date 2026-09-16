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
    /// ⚠️ 아래 두 키는 StorageView가 자체 보유하던 `StorageDiskScopeBookmarks`에서
    ///   이관됐다. rawValue는 기존 사용자의 UserDefaults에 이미 저장된 문자열과
    ///   반드시 동일해야 업데이트 후에도 폴더 접근 권한이 유지된다.
    case storageHomeFolder = "TriClean.Storage.DiskUsage.HomeFolderBookmark"
    case storageApplicationsFolders = "TriClean.Storage.DiskUsage.ApplicationsFolderBookmarks"
    /// 대용량 파일 화면의 스캔 폴더. 기존에는 이 화면만 북마크를 저장하지 않아
    /// 앱을 다시 켤 때마다 폴더를 다시 골라야 했다.
    case largeFilesScanFolder = "TriClean.LargeFiles.FolderBookmark"

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
                "북마크 저장 실패 key=\(key.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
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
            if isStale {
                // ⚠️ bookmarkData(.withSecurityScope)는 스코프가 열린 상태에서만 성공한다.
                //   스코프를 열지 않고 호출하면 매번 실패해 stale 북마크가 갱신되지 않는다.
                let token = SecurityScopedAccessToken(url: url)
                defer { token?.stop() }
                trySave(url: url, for: key)
            }
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

    // MARK: - 다중 URL (예: /Applications + ~/Applications)

    /// 여러 폴더를 하나의 키에 저장한다.
    ///
    /// 저장 형식은 `[Data]`를 PropertyList로 인코딩한 blob이며,
    /// StorageView가 쓰던 기존 형식과 동일하다(마이그레이션 불필요).
    /// 단일 URL용 `save(url:for:)`와는 저장 형식이 다르므로 한 키에 섞어 쓰지 말 것.
    func saveMany(urls: [URL], for key: TriCleanBookmarkKey) throws {
        let normalized = Self.normalized(urls)

        guard !normalized.isEmpty else {
            clear(key)
            return
        }

        let datas = try normalized.map { url in
            try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        let blob = try PropertyListEncoder().encode(datas)
        defaults.set(blob, forKey: key.rawValue)
        defaults.set(normalized.map { $0.path }.joined(separator: "\n"), forKey: key.pathKey)
    }

    /// 저장 실패를 삼키지 않고 로그로 남긴다. (`trySave(url:for:)`와 동일한 정책)
    @discardableResult
    func trySaveMany(urls: [URL], for key: TriCleanBookmarkKey) -> Bool {
        do {
            try saveMany(urls: urls, for: key)
            return true
        } catch {
            bookmarkLogger.error(
                "북마크 다중 저장 실패 key=\(key.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    /// 다중 URL을 복원한다. 개별 항목 복원 실패는 건너뛰고 나머지를 반환하며,
    /// stale 북마크가 하나라도 있으면 복원된 목록으로 다시 저장한다.
    func resolveURLs(for key: TriCleanBookmarkKey) -> [URL] {
        guard let blob = defaults.data(forKey: key.rawValue) else { return [] }

        let datas: [Data]
        do {
            datas = try PropertyListDecoder().decode([Data].self, from: blob)
        } catch {
            bookmarkLogger.error(
                "북마크 다중 복원 실패 key=\(key.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            return []
        }

        var urls: [URL] = []
        urls.reserveCapacity(datas.count)
        var hasStale = false

        for data in datas {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }

            urls.append(url)
            hasStale = hasStale || isStale
        }

        let resolved = Self.normalized(urls)
        if hasStale {
            // ⚠️ 단일 키와 같은 이유로 스코프를 열고 갱신한다.
            let tokens = resolved.compactMap { SecurityScopedAccessToken(url: $0) }
            defer { tokens.forEach { $0.stop() } }
            trySaveMany(urls: resolved, for: key)
        }
        return resolved
    }

    /// 중복 제거 + 경로 정렬. 표준화된 경로로 비교하되 **원본 URL을 반환**한다.
    /// (보안 스코프 접근은 북마크에서 복원한 원본 URL로 시작해야 한다 —
    ///  standardized URL은 스코프가 열리지 않을 수 있다.)
    private static func normalized(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where seen.insert(url.standardizedFileURL.path).inserted {
            result.append(url)
        }
        return result.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
    }
}

/// 보안 스코프 접근을 RAII로 관리합니다.
/// 내부 상태를 NSLock으로 보호하므로 여러 컨텍스트에서 stop()을 호출해도 안전합니다.
final class SecurityScopedAccessToken: @unchecked Sendable {
    private let url: URL
    private let didStart: Bool

    private let lock = NSLock()

    /// ⚠️ `nonisolated(unsafe)`: 이 프로젝트는 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`라
    ///   저장 프로퍼티까지 MainActor로 추론된다. 이 토큰은 백그라운드
    ///   `Task.detached`에서 생성·해제되어야 하므로 격리를 해제한다.
    ///   `unsafe`의 안전성 근거는 바로 위 `lock`이다 — 이 값을 읽고 쓰는 곳은
    ///   `stop()` 하나뿐이며 전 구간이 `lock`으로 보호된다.
    ///   (클래스의 `@unchecked Sendable`도 동일한 근거에 기반한 선언이다.)
    private nonisolated(unsafe) var didStop = false

    /// ⚠️ `nonisolated` 명시: 위와 같은 이유로 초기화·해제가 MainActor에
    ///   종속되지 않아야 한다. 백그라운드 폴더 순회(StorageViewModel 등)에서 호출된다.
    nonisolated init?(url: URL) {
        self.url = url
        self.didStart = url.startAccessingSecurityScopedResource()
        if !didStart { return nil }
    }

    nonisolated func stop() {
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
