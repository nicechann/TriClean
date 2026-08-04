//
//  DeletionSafety.swift
//  TriClean
//
//  삭제 대상 경로 검증을 한곳에 모은 타입.
//  모든 삭제 경로는 보안 스코프 접근을 시작한 뒤 이 타입으로 재검증해야 한다.
//

import Foundation

nonisolated enum DeletionSafety {

    /// 삭제를 허용할 경로 범위.
    /// - descendantsOnly: 지정 폴더의 하위 항목만 허용하며 루트 자체는 거부합니다.
    /// - exactItem: 사용자가 직접 선택한 단일 파일/앱 번들 자체만 허용합니다.
    nonisolated struct Scope: Sendable {
        nonisolated enum Policy: Sendable {
            case descendantsOnly
            case exactItem
        }

        let url: URL
        let policy: Policy

        nonisolated static func descendants(of url: URL) -> Scope {
            Scope(url: url, policy: .descendantsOnly)
        }

        nonisolated static func exact(_ url: URL) -> Scope {
            Scope(url: url, policy: .exactItem)
        }
    }

    /// 심볼릭 링크를 해석한 표준 경로를 반환합니다.
    nonisolated static func resolvedPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 경계 검사가 가능한 스코프 경로를 만든다.
    /// 심볼릭 링크를 해석하고(`/var` → `/private/var`) 트레일링 슬래시를 붙여
    /// `/Users/me/Library2`가 `/Users/me/Library` 하위로 오판되는 것을 막는다.
    nonisolated static func scopePath(for url: URL) -> String {
        let resolved = resolvedPath(for: url)
        return resolved.hasSuffix("/") ? resolved : resolved + "/"
    }

    /// `url`이 `scopePath` **하위**에 있는지 검사한다. 스코프 루트 자신은 거부한다.
    nonisolated static func isContained(_ url: URL, in scopePath: String) -> Bool {
        let target = resolvedPath(for: url)
        guard target.count > scopePath.count else { return false }
        return target.hasPrefix(scopePath)
    }

    nonisolated static func isContained(_ url: URL, inScope scope: URL) -> Bool {
        isContained(url, in: scopePath(for: scope))
    }

    /// 두 URL이 심볼릭 링크 해석 후 같은 파일 경로를 가리키는지 확인합니다.
    nonisolated static func isSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        resolvedPath(for: lhs) == resolvedPath(for: rhs)
    }

    /// 대상 URL이 하나 이상의 허용 범위에 포함되는지 검사합니다.
    nonisolated static func isAllowed(_ url: URL, in scopes: [Scope]) -> Bool {
        scopes.contains { scope in
            switch scope.policy {
            case .descendantsOnly:
                return isContained(url, inScope: scope.url)
            case .exactItem:
                return isSameItem(url, scope.url)
            }
        }
    }

    /// 단일 폴더 하위에 있고 실제로 존재하는 대상만 남긴다. 중복 경로는 제거한다.
    /// 기존 호출부 호환을 위한 편의 오버로드입니다.
    nonisolated static func sanitize<T>(
        _ candidates: [T],
        scope: URL,
        url: (T) -> URL
    ) -> (accepted: [T], rejectedCount: Int) {
        sanitize(candidates, scopes: [.descendants(of: scope)], url: url)
    }

    /// 허용 범위 안에 있고 실제로 존재하는 대상만 남긴다. 중복 경로는 제거한다.
    ///
    /// 반드시 보안 스코프 접근을 시작한 뒤 호출해야 합니다. 스캔과 삭제 사이에
    /// 파일이 사라졌거나 심볼릭 링크가 바뀐 경우도 삭제 직전에 걸러냅니다.
    /// - Returns: 검증을 통과한 대상과, 걸러진 대상의 개수
    nonisolated static func sanitize<T>(
        _ candidates: [T],
        scopes: [Scope],
        url: (T) -> URL
    ) -> (accepted: [T], rejectedCount: Int) {
        guard !scopes.isEmpty else { return ([], candidates.count) }

        let fm = FileManager.default
        var seen = Set<String>()
        var accepted: [T] = []
        var rejected = 0

        for candidate in candidates {
            let target = url(candidate).standardizedFileURL
            guard isAllowed(target, in: scopes) else { rejected += 1; continue }
            guard fm.fileExists(atPath: target.path) else { rejected += 1; continue }

            let resolved = resolvedPath(for: target)
            guard seen.insert(resolved).inserted else { rejected += 1; continue }
            accepted.append(candidate)
        }

        return (accepted, rejected)
    }

    /// 단일 항목이 스캔 시 저장한 파일 시스템 식별 정보와 여전히 일치하는지 확인합니다.
    /// 일괄 검증 이후 실제 삭제까지 시간이 지난 경우, `trashItem` 직전에 다시 호출합니다.
    nonisolated static func isIdentityCurrent<T>(
        _ candidate: T,
        url: (T) -> URL,
        identity: (T) -> FileIdentitySnapshot?
    ) -> Bool {
        guard let snapshot = identity(candidate) else { return false }
        return snapshot.matchesCurrentItem(at: url(candidate))
    }

    /// 스캔 시 저장한 파일 시스템 식별 정보와 현재 항목이 일치하는 대상만 남깁니다.
    /// 같은 경로가 다른 파일이나 폴더로 교체된 경우 삭제에서 제외합니다.
    nonisolated static func revalidateIdentity<T>(
        _ candidates: [T],
        url: (T) -> URL,
        identity: (T) -> FileIdentitySnapshot?
    ) -> (accepted: [T], rejectedCount: Int) {
        var accepted: [T] = []
        var rejected = 0

        for candidate in candidates {
            guard isIdentityCurrent(candidate, url: url, identity: identity) else {
                rejected += 1
                continue
            }
            accepted.append(candidate)
        }

        return (accepted, rejected)
    }

}
