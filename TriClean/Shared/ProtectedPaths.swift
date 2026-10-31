//
//  ProtectedPaths.swift
//  TriClean
//
//  사용자가 고른 폴더 안이라도 통째로 휴지통에 넣으면 안 되는 위치.
//
//  ⚠️ 대용량 파일 화면은 스캔 루트 바로 아래 폴더를 한 행으로 보여 주고, 온보딩의 "홈 허용"은
//     스캔 루트를 홈 폴더로 기본 설정한다. 경계 검사(`.descendants(of: 루트)`)만으로는
//     ~/Pictures(사진 보관함 포함)·~/Documents·~/Library 하위 1단계 폴더가 확인 한 번으로
//     통째로 휴지통에 갈 수 있다. 이 규칙으로 표시 단계와 삭제 직전 모두 걸러낸다.
//

import Foundation
import Darwin

nonisolated enum ProtectedPaths {

    /// macOS가 만들고 관리하는 홈 폴더 하위 기본 폴더.
    static let standardHomeFolderNames: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads", "Library",
        "Movies", "Music", "Pictures", "Public"
    ]

    /// 앱이 관리하는 미디어 보관함 패키지. 폴더째 지우면 보관함 전체가 사라진다.
    static let managedLibraryExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary",
        "musiclibrary", "tvlibrary"
    ]

    /// 확장자 없이 이름으로만 알아볼 수 있는 보관함.
    static let managedLibraryNames: Set<String> = ["Photo Booth Library"]

    /// 동기화 서비스의 루트가 모이는 ~/Library 하위 폴더. 그 바로 아래 항목(iCloud Drive,
    /// Dropbox·Google Drive 등)을 휴지통에 넣으면 삭제가 다른 기기에도 전파된다.
    static let syncContainerPaths: [String] = ["Library/Mobile Documents", "Library/CloudStorage"]

    static func isManagedLibrary(_ url: URL) -> Bool {
        managedLibraryExtensions.contains(url.pathExtension.lowercased())
            || managedLibraryNames.contains(url.lastPathComponent)
    }

    /// 샌드박스 앱의 `NSHomeDirectory()`는 컨테이너 경로라서 실제 사용자 홈을 따로 구한다.
    static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// 통째로 휴지통에 넣으면 안 되는 위치인지.
    /// - 홈 폴더 자신, 홈 바로 아래의 기본 폴더(Documents·Pictures·Library 등)
    /// - ~/Library 바로 아래 항목(Application Support·Containers·Preferences 등)
    /// - iCloud Drive·CloudStorage 제공자 폴더(~/Library/Mobile Documents·CloudStorage 바로 아래)
    /// - 사진·음악·TV·Photo Booth 보관함(어디에 있든)
    ///
    /// 보관함을 **담은** 폴더(예: ~/Music/Music)는 경로만으로 알 수 없어, 스캔이 남긴
    /// `FolderInfo.containsManagedLibrary`로 따로 막는다.
    ///
    /// `resolvingSymlinks`가 false면 디스크를 읽지 않고 표기만으로 판단한다(목록 렌더링용).
    /// 삭제 직전에는 반드시 true로 다시 검사한다.
    static func isProtected(_ url: URL, home: URL = realHomeDirectory, resolvingSymlinks: Bool = true) -> Bool {
        let target = resolvingSymlinks ? DeletionSafety.resolvedPath(for: url) : url.standardizedFileURL.path
        let homePath = resolvingSymlinks ? DeletionSafety.resolvedPath(for: home) : home.standardizedFileURL.path

        if isManagedLibrary(url) { return true }
        if target == homePath { return true }

        let parent = (target as NSString).deletingLastPathComponent
        if parent == homePath, standardHomeFolderNames.contains((target as NSString).lastPathComponent) {
            return true
        }

        let libraryPath = (homePath as NSString).appendingPathComponent("Library")
        if parent == libraryPath { return true }

        return syncContainerPaths.contains { (homePath as NSString).appendingPathComponent($0) == parent }
    }
}
