//
//  FileIdentitySnapshot.swift
//  TriClean
//
//  스캔 시점의 파일 시스템 항목 정체성을 저장하고 삭제 직전에 같은 항목인지 재검증합니다.
//  같은 경로에 다른 파일이나 폴더가 새로 생긴 경우 경로 존재 여부만으로 삭제를 허용하지 않습니다.
//

import Foundation
import Darwin

struct FileIdentitySnapshot: Hashable, Sendable {
    nonisolated enum ItemType: UInt8, Hashable, Sendable {
        case regularFile
        case directory
    }

    let device: UInt64
    let inode: UInt64
    let itemType: ItemType
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    nonisolated init(
        device: UInt64,
        inode: UInt64,
        itemType: ItemType,
        size: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.itemType = itemType
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
    }

    nonisolated static func == (lhs: FileIdentitySnapshot, rhs: FileIdentitySnapshot) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.itemType == rhs.itemType
            && lhs.size == rhs.size
            && lhs.modificationSeconds == rhs.modificationSeconds
            && lhs.modificationNanoseconds == rhs.modificationNanoseconds
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(device)
        hasher.combine(inode)
        hasher.combine(itemType)
        hasher.combine(size)
        hasher.combine(modificationSeconds)
        hasher.combine(modificationNanoseconds)
    }

    /// 일반 파일만 캡처합니다. 사진·중복 파일의 기존 호출부와 호환됩니다.
    nonisolated static func capture(_ url: URL) -> FileIdentitySnapshot? {
        guard let snapshot = captureItem(url), snapshot.itemType == .regularFile else { return nil }
        return snapshot
    }

    /// 일반 파일 또는 실제 디렉터리를 캡처합니다.
    /// 심볼릭 링크와 그 밖의 특수 파일은 삭제 대상으로 인정하지 않습니다.
    nonisolated static func captureItem(_ url: URL) -> FileIdentitySnapshot? {
        var info = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return lstat(path, &info)
        }

        guard result == 0 else { return nil }

        let itemType: ItemType
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            itemType = .regularFile
        case S_IFDIR:
            itemType = .directory
        default:
            return nil
        }

        return FileIdentitySnapshot(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            itemType: itemType,
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    nonisolated func matchesCurrentFile(at url: URL) -> Bool {
        itemType == .regularFile && Self.capture(url.standardizedFileURL) == self
    }

    nonisolated func matchesCurrentItem(at url: URL) -> Bool {
        matchesCurrentItem(at: url, allowDirectoryContentChanges: false)
    }

    /// 캐시·로그 디렉터리는 내부 파일이 생성·변경되면 크기와 수정 시각이 달라질 수 있습니다.
    /// 이 옵션을 켜도 device·inode·항목 유형은 반드시 같아야 하므로, 같은 경로가 다른
    /// 디렉터리로 교체된 경우에는 계속 삭제를 거부합니다. 일반 파일은 항상 엄격 비교합니다.
    nonisolated func matchesCurrentItem(
        at url: URL,
        allowDirectoryContentChanges: Bool
    ) -> Bool {
        guard let current = Self.captureItem(url.standardizedFileURL) else { return false }
        guard device == current.device,
              inode == current.inode,
              itemType == current.itemType
        else { return false }

        if itemType == .directory && allowDirectoryContentChanges {
            return true
        }

        return current == self
    }
}
