//
//  DuplicateGroup.swift
//  TriClean
//
//  중복 파일 그룹 모델
//

import Foundation

/// 동일한 내용을 가진 파일들의 그룹
struct DuplicateGroup: Identifiable {
    let id = UUID()
    let hash: String           // SHA-256 해시 (또는 부분 해시)
    let fileSize: Int64        // 각 파일의 크기 (모두 동일)
    var files: [DuplicateFile]

    /// 원본 1개를 제외한 복사본 수
    var duplicateCount: Int { max(0, files.count - 1) }

    /// 복사본을 삭제하면 확보할 수 있는 용량
    var reclaimableBytes: Int64 { Int64(duplicateCount) * fileSize }

    var reclaimableString: String {
        ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
    }

    var fileSizeString: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var keepCount: Int {
        files.filter { $0.isKeep }.count
    }

    var selectedDeleteCount: Int {
        files.filter { !$0.isKeep }.count
    }

    var selectedDeleteBytes: Int64 {
        Int64(selectedDeleteCount) * fileSize
    }

    var selectedDeleteBytesString: String {
        ByteCountFormatter.string(fromByteCount: selectedDeleteBytes, countStyle: .file)
    }

    var keptFile: DuplicateFile? {
        files.first(where: { $0.isKeep })
    }
}

/// 중복 그룹 내 개별 파일
struct DuplicateFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let modificationDate: Date?
    var isKeep: Bool = false    // true = 보존, false = 삭제 대상

    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var parentFolder: String {
        url.deletingLastPathComponent().lastPathComponent
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DuplicateFile, rhs: DuplicateFile) -> Bool { lhs.id == rhs.id }
}

/// 스캔 진행 상태
enum DuplicateScanPhase: String {
    case idle = "대기"
    case collectingFiles = "파일 수집 중..."
    case groupingBySize = "크기별 그룹화 중..."
    case hashingPartial = "부분 해시 비교 중..."
    case hashingFull = "전체 해시 비교 중..."
    case done = "완료"
}
