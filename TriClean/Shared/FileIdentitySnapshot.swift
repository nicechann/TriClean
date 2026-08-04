//
//  FileIdentitySnapshot.swift
//  TriClean
//
//  스캔 시점의 파일 정체성을 저장하고 삭제 직전에 같은 파일인지 재검증합니다.
//  같은 경로에 다른 파일이 새로 생긴 경우 경로 존재 여부만으로 삭제를 허용하지 않습니다.
//

import Foundation
import Darwin

struct FileIdentitySnapshot: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    nonisolated init(
        device: UInt64,
        inode: UInt64,
        size: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
    }

    nonisolated static func == (lhs: FileIdentitySnapshot, rhs: FileIdentitySnapshot) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.size == rhs.size
            && lhs.modificationSeconds == rhs.modificationSeconds
            && lhs.modificationNanoseconds == rhs.modificationNanoseconds
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(device)
        hasher.combine(inode)
        hasher.combine(size)
        hasher.combine(modificationSeconds)
        hasher.combine(modificationNanoseconds)
    }

    nonisolated static func capture(_ url: URL) -> FileIdentitySnapshot? {
        var info = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return lstat(path, &info)
        }

        guard result == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }

        return FileIdentitySnapshot(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    nonisolated func matchesCurrentFile(at url: URL) -> Bool {
        Self.capture(url.standardizedFileURL) == self
    }
}
