//
//  PhotoModels.swift
//  TriClean
//
//  사진 관리자(파일 기반 폴더 스캔) 모델.
//  - 다른 스캐너(Junk/Duplicate)와 동일하게 사용자 선택 폴더만 다루며,
//    삭제는 전부 휴지통 이동(trashItem)으로 복구 가능합니다.
//  - 1단계(스캐폴딩)에서는 폴더 내 이미지 수집까지만 수행하고,
//    유사/흐릿/스크린샷 분류는 이후 단계에서 PhotoCategory로 채워집니다.
//

import Foundation

/// 사진 분류. 1단계에서는 .all만 채워지고, 이후 단계에서 나머지가 활성화됩니다.
enum PhotoCategory: String, CaseIterable, Identifiable, Sendable {
    case all
    case similar
    case blurry
    case screenshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:        return "photos.category.all".localized
        case .similar:    return "photos.category.similar".localized
        case .blurry:     return "photos.category.blurry".localized
        case .screenshot: return "photos.category.screenshot".localized
        }
    }

    var icon: String {
        switch self {
        case .all:        return "photo.on.rectangle.angled"
        case .similar:    return "square.on.square"
        case .blurry:     return "drop.fill"
        case .screenshot: return "camera.viewfinder"
        }
    }
}

/// 폴더에서 발견된 개별 이미지 파일.
struct PhotoItem: Identifiable, Hashable, Sendable {
    let id: String          // url.path (안정적 고유키)
    let url: URL
    let sizeBytes: Int64
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int

    /// 이후 단계(삭제 UI)에서 사용. 1단계에서는 항상 false로 시작합니다.
    var isSelected: Bool = false

    /// 스크린샷 여부 (2단계: kMDItemIsScreenCapture / 파일명 패턴 기반).
    let isScreenshot: Bool

    var name: String { url.lastPathComponent }
    var path: String { url.path }

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var dimensionText: String {
        guard pixelWidth > 0, pixelHeight > 0 else { return "—" }
        return "\(pixelWidth)×\(pixelHeight)"
    }

    nonisolated init(
        url: URL,
        sizeBytes: Int64,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        isScreenshot: Bool = false,
        isSelected: Bool = false
    ) {
        self.id = url.path
        self.url = url
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isScreenshot = isScreenshot
        self.isSelected = isSelected
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool { lhs.id == rhs.id }
}

/// 스캔 진행 단계.
enum PhotoScanPhase: String, Sendable {
    case idle
    case collecting
    case reading
    case done

    var displayText: String {
        switch self {
        case .idle:       return "photos.phase.idle".localized
        case .collecting: return "photos.phase.collecting".localized
        case .reading:    return "photos.phase.reading".localized
        case .done:       return "photos.phase.done".localized
        }
    }
}
