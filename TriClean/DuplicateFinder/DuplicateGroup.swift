//
//  DuplicateGroup.swift
//  TriClean
//
//  중복 파일 그룹 모델
//

import Foundation

/// 동일한 내용을 가진 파일들의 그룹
// ⚠️ 아래 타입들은 전부 `nonisolated`다.
//   `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 때문에 명시하지 않으면 타입과
//   **합성 conformance(Equatable/Hashable)**, 계산 프로퍼티까지 MainActor로 추론된다.
//   이 값들은 `Task.detached` 스캔·해시 작업에서 생성·비교·정렬된다.
//   `Sendable` 선언만으로는 conformance 격리가 풀리지 않는다.
nonisolated struct DuplicateGroup: Identifiable, Sendable {
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
nonisolated struct DuplicateFile: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let modificationDate: Date?
    let fileIdentity: FileIdentitySnapshot?
    var isKeep: Bool = false    // true = 보존, false = 삭제 대상

    init(
        url: URL,
        modificationDate: Date?,
        fileIdentity: FileIdentitySnapshot? = nil,
        isKeep: Bool = false
    ) {
        self.url = url
        self.modificationDate = modificationDate
        self.fileIdentity = fileIdentity ?? FileIdentitySnapshot.capture(url)
        self.isKeep = isKeep
    }

    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var parentFolder: String {
        url.deletingLastPathComponent().lastPathComponent
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DuplicateFile, rhs: DuplicateFile) -> Bool { lhs.id == rhs.id }
}

/// 스캔 진행 상태
nonisolated enum DuplicateScanPhase: String, Sendable {
    case idle
    case collectingFiles
    case groupingBySize
    case hashingPartial
    case hashingFull
    case done
    case accessDenied

    var displayText: String {
        switch self {
        case .idle:            return "duplicate.phase.idle".localized
        case .collectingFiles: return "duplicate.phase.collecting".localized
        case .groupingBySize:  return "duplicate.phase.grouping".localized
        case .hashingPartial:  return "duplicate.phase.partial_hash".localized
        case .hashingFull:     return "duplicate.phase.full_hash".localized
        case .done:            return "duplicate.phase.done".localized
        case .accessDenied:    return "duplicate.phase.access_denied".localized
        }
    }
}
