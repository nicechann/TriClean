//
//  CloudFileStatus.swift
//  TriClean
//
//  로컬에 실제 데이터가 없는 "클라우드 전용" 파일을 판별합니다.
//
//  ⚠️ 왜 필요한가
//  iCloud Drive의 "Mac 저장 공간 최적화", Dropbox Smart Sync, OneDrive Files On-Demand 등은
//  파일 내용을 서버에만 두고 로컬에는 자리표시자(placeholder)만 남긴다. 이런 파일은
//  **논리 크기는 원본 그대로**인데 **실제 점유 블록은 0**이다.
//
//  문제는 이 파일의 바이트를 한 번이라도 읽으면 macOS가 파일 전체를 내려받는다는 점이다.
//  즉 다음 동작이 전부 대용량 다운로드를 유발한다.
//    - `DuplicateScannerViewModel.partialHash` / `fullHash` (FileHandle 읽기)
//    - `PhotoScannerViewModel.imagePixelDimensions` / `differenceHash` / `blurVariance`
//      (`CGImageSourceCreateWithURL`는 헤더만 읽어도 자리표시자를 실체화한다)
//
//  디스크 공간을 확보하려고 켠 스캔이 오히려 수십~수백 GB를 내려받아 디스크를 채우는
//  결과가 되므로, **바이트를 읽기 전에** 걸러내야 한다.
//
//  게다가 이런 파일은 지워도 로컬 공간이 늘지 않는다(이미 0바이트다).
//  스캔 대상에서 제외하는 것이 기능적으로도 맞다.
//
//  ✅ 판정은 `URLResourceValues`만 읽으므로 그 자체로는 다운로드를 유발하지 않는다.
//

import Foundation

nonisolated enum CloudFileStatus {

    /// 판정에 필요한 리소스 키. 호출부의 `includingPropertiesForKeys`에 반드시 합쳐 넣어야 한다.
    static let requiredResourceKeys: [URLResourceKey] = [
        .ubiquitousItemDownloadingStatusKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .volumeIsLocalKey
    ]

    /// 로컬에 내용이 없는 자리표시자 파일인지 판정합니다.
    ///
    /// 두 가지 경로로 확인한다.
    ///  1. iCloud Drive는 `ubiquitousItemDownloadingStatus`로 정확히 알 수 있다.
    ///  2. 서드파티 File Provider(Dropbox·OneDrive 등)는 위 키가 채워지지 않는다.
    ///     이때는 "논리 크기는 있는데 할당된 블록이 0"이라는 물리적 사실로 판정한다.
    ///
    /// - Parameter values: 이미 읽어둔 리소스 값. `requiredResourceKeys`가 포함되어 있어야 한다.
    static func isDataless(_ values: URLResourceValues) -> Bool {
        // 1) iCloud가 상태를 알려주면 그것으로 확정한다.
        //    확정된 경우 아래 블록 휴리스틱으로 다시 판정하지 않는다 —
        //    "로컬에 있다"고 확인된 파일이 블록 수 때문에 뒤집히면 안 된다.
        if let status = values.ubiquitousItemDownloadingStatus {
            return status != .current && status != .downloaded
        }

        // 2) 서드파티 File Provider(Dropbox·OneDrive 등)는 위 키가 비어 있다.
        //    이때는 "논리 크기는 있는데 점유 블록이 0"이라는 물리적 사실로 판정한다.
        //
        // ⚠️ 단, 이 휴리스틱은 **로컬 볼륨에서만** 신뢰할 수 있다.
        //    SMB/NFS 등 네트워크 볼륨과 일부 FUSE 파일시스템은 서버가 할당 정보를
        //    주지 않아 `totalFileAllocatedSize`를 nil이 아니라 **0으로 채운다**.
        //    그대로 적용하면 NAS 폴더의 파일이 통째로 스캔에서 사라진다.
        //    볼륨이 원격임이 확인되면 판정을 포기한다(제외하지 않는다).
        guard values.volumeIsLocal != false else { return false }

        let logicalSize = values.fileSize ?? 0
        guard logicalSize > 0 else { return false }

        // 할당 크기를 읽지 못했다면 판단 근거가 없으므로 "아니다"로 둔다.
        // (근거 없이 제외하면 멀쩡한 파일이 스캔에서 조용히 사라진다.)
        guard let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize else {
            return false
        }

        return allocated == 0
    }
}
