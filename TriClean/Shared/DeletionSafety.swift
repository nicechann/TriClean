//
//  DeletionSafety.swift
//  TriClean
//
//  삭제 대상 경로 검증을 한곳에 모은 타입.
//  기존에는 LargeFilesView에만 경계 검사 로직이 있었고 Junk / Duplicate /
//  Photos / Apps 삭제 경로에는 검증이 없었다. 모든 삭제가 동일한 검증을
//  거치도록 공용화한다.
//
//  ⚠️ 새로 추가되는 삭제 경로는 반드시 이 타입을 통과시킬 것.
//

import Foundation

enum DeletionSafety {

    /// 경계 검사가 가능한 스코프 경로를 만든다.
    /// 심볼릭 링크를 해석하고(`/var` → `/private/var`) 트레일링 슬래시를 붙여
    /// `/Users/me/Library2`가 `/Users/me/Library` 하위로 오판되는 것을 막는다.
    nonisolated static func scopePath(for url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.hasSuffix("/") ? resolved : resolved + "/"
    }

    /// `url`이 `scopePath` **하위**에 있는지 검사한다. 스코프 루트 자신은 거부한다.
    nonisolated static func isContained(_ url: URL, in scopePath: String) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard target.count > scopePath.count else { return false }
        return target.hasPrefix(scopePath)
    }

    nonisolated static func isContained(_ url: URL, inScope scope: URL) -> Bool {
        isContained(url, in: scopePath(for: scope))
    }

    /// 스코프 하위에 있고 실제로 존재하는 대상만 남긴다. 중복 경로는 제거한다.
    ///
    /// 스캔 시점과 삭제 시점 사이에 파일이 사라졌거나 경로가 조작된 경우를 걸러낸다.
    /// - Returns: 검증을 통과한 대상과, 걸러진 대상의 개수
    nonisolated static func sanitize<T>(
        _ candidates: [T],
        scope: URL,
        url: (T) -> URL
    ) -> (accepted: [T], rejectedCount: Int) {
        let root = scopePath(for: scope)
        let fm = FileManager.default
        var seen = Set<String>()
        var accepted: [T] = []
        var rejected = 0

        for candidate in candidates {
            let target = url(candidate).standardizedFileURL
            guard isContained(target, in: root) else { rejected += 1; continue }
            guard fm.fileExists(atPath: target.path) else { rejected += 1; continue }
            guard seen.insert(target.resolvingSymlinksInPath().path).inserted else { rejected += 1; continue }
            accepted.append(candidate)
        }

        return (accepted, rejected)
    }
}
