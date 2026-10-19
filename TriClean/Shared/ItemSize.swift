//
//  ItemSize.swift
//  TriClean
//
//  휴지통으로 옮길 항목이 실제로 차지하는 디스크 크기(할당 크기)를 잰다.
//  정크·앱 잔여 파일처럼 "폴더째" 휴지통으로 가는 항목은 표시 크기와 실제 이동 범위가 같아야 한다.
//

import Foundation

nonisolated enum ItemSize {

    private static let keys: Set<URLResourceKey> = [
        .isSymbolicLinkKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey
    ]

    /// 항목의 할당 크기 합계.
    ///
    /// - 숨김 파일·숨김 폴더(`.git`, `.DS_Store` 등)도 합산한다. 폴더는 통째로 휴지통으로 가므로
    ///   `.skipsHiddenFiles`로 빼면 사용자는 "250 MB"를 지운다고 보고 실제로는 수 GB를 지우게 된다.
    /// - 심볼릭 링크는 따라가지 않는다. 대상 자신이 링크면 0이고, 하위의 링크는 링크 대상의
    ///   크기를 더하지 않는다(외부 경로 탐색·중복 합산 방지). `trashItem`도 링크 자체만 옮긴다.
    /// - 취소되면 0을 반환한다(호출부는 취소된 결과를 버린다).
    static func allocatedBytes(at url: URL) -> Int64 {
        guard !Task.isCancelled,
              let values = try? url.resourceValues(forKeys: keys),
              values.isSymbolicLink != true
        else { return 0 }

        guard values.isDirectory == true else {
            return values.isRegularFile == true ? bytes(of: values) : 0
        }

        // 하위의 심볼릭 링크는 열거만 되고 따라가지 않는다(루트가 링크인 경우는 위에서 걸렀다).
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        while let object = enumerator.nextObject() {
            if Task.isCancelled { return 0 }
            autoreleasepool {
                guard let child = object as? URL,
                      let childValues = try? child.resourceValues(forKeys: keys),
                      childValues.isSymbolicLink != true,
                      childValues.isRegularFile == true
                else { return }
                total += bytes(of: childValues)
            }
        }
        return total
    }

    private static func bytes(of values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }
}
