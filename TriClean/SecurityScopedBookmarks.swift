//
//  SecurityScopedBookmarks.swift
//  TriClean
//
//  Created by changyu Kang on 17/12/2025.
//

import Foundation

enum TriCleanBookmarkKey: String {
    case storageRoot = "TriClean.Bookmark.StorageRoot"
    case applicationsFolder = "TriClean.Bookmark.ApplicationsFolder"
    case userLibraryFolder = "TriClean.Bookmark.UserLibraryFolder"

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
            if isStale { try? save(url: url, for: key) }
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

final class SecurityScopedAccessToken {
    private let url: URL
    private let didStart: Bool

    init?(url: URL) {
        self.url = url
        self.didStart = url.startAccessingSecurityScopedResource()
        if !didStart { return nil }
    }

    deinit {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
}
