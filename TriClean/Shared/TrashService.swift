//
//  TrashService.swift
//  TriClean
//
//  휴지통 이동을 수행하는 단일 지점.
//
//  기존에는 "삭제 직전 재검증 → trashItem → 재검증 → NSWorkspace.recycle 폴백"
//  패턴이 Junk / Duplicate / Photos / LargeFiles / Apps 5곳에 각각 복제되어 있었고,
//  재검증 순서와 실패 처리가 조금씩 달랐다. 안전 규칙이 흩어져 있으면
//  한 곳을 고칠 때 다른 곳이 누락되므로 이 타입으로 모은다.
//
//  호출 규약:
//  - 반드시 보안 스코프 접근을 시작한 뒤에 호출해야 한다.
//  - 경로 경계 검사(DeletionSafety.sanitize)는 호출부에서 이미 수행했거나,
//    sanitizeAndMoveToTrash(_:scopes:...)를 사용해 함께 수행한다.
//

import Foundation
import AppKit
import os.log

nonisolated enum TrashService {

    /// 사용자에게 보여줄 수 있는 실패 정보.
    nonisolated struct Failure: Sendable {
        let path: String
        let domain: String
        let code: Int
        let message: String

        nonisolated init(url: URL, error: Error) {
            let nsError = error as NSError
            self.path = url.path
            self.domain = nsError.domain
            self.code = nsError.code
            self.message = nsError.localizedDescription
        }
    }

    /// 삭제 결과.
    /// - succeeded: 휴지통으로 옮겨진 항목
    /// - failed: 시도했으나 실패한 항목
    /// - excluded: 경계 검사·정체성 재검증에서 제외되어 시도조차 하지 않은 항목
    nonisolated struct Outcome<Item>: Sendable where Item: Sendable {
        let succeeded: [Item]
        let failed: [Item]
        let excluded: [Item]
        let firstFailure: Failure?

        var succeededCount: Int { succeeded.count }
        var failedCount: Int { failed.count }
        var excludedCount: Int { excluded.count }
    }

    /// 경로 경계 검사와 정체성 재검증을 함께 수행한 뒤 휴지통으로 옮긴다.
    nonisolated static func sanitizeAndMoveToTrash<Item: Sendable>(
        _ candidates: [Item],
        scopes: [DeletionSafety.Scope],
        url: (Item) -> URL,
        identity: (Item) -> FileIdentitySnapshot?,
        allowsDirectoryContentChanges: (Item) -> Bool = { _ in false },
        logCategory: String
    ) async -> Outcome<Item> {
        let partitioned = DeletionSafety.partition(candidates, scopes: scopes, url: url)

        let outcome = await moveToTrash(
            partitioned.accepted,
            url: url,
            identity: identity,
            allowsDirectoryContentChanges: allowsDirectoryContentChanges,
            logCategory: logCategory
        )

        return Outcome(
            succeeded: outcome.succeeded,
            failed: outcome.failed,
            excluded: partitioned.rejected + outcome.excluded,
            firstFailure: outcome.firstFailure
        )
    }

    /// 이미 경계 검사를 마친 대상을 휴지통으로 옮긴다.
    ///
    /// 각 항목마다 다음 순서를 지킨다.
    ///  1. 휴지통 이동 직전에 스캔 당시와 같은 항목인지 확인(다른 항목을 처리하는
    ///     사이 같은 경로가 교체될 수 있으므로 루프 안에서 매번 검사한다)
    ///  2. `FileManager.trashItem`
    ///  3. 실패 시 다시 정체성을 확인한 뒤에만 `NSWorkspace.recycle` 폴백
    nonisolated static func moveToTrash<Item: Sendable>(
        _ targets: [Item],
        url: (Item) -> URL,
        identity: (Item) -> FileIdentitySnapshot?,
        allowsDirectoryContentChanges: (Item) -> Bool = { _ in false },
        logCategory: String
    ) async -> Outcome<Item> {
        let logger = Logger(subsystem: "com.nicechann.TriClean", category: logCategory)
        let fm = FileManager.default

        var succeeded: [Item] = []
        var failed: [Item] = []
        var excluded: [Item] = []
        var firstFailure: Failure?

        for target in targets {
            let targetURL = url(target).standardizedFileURL

            guard isIdentityCurrent(
                target,
                url: url,
                identity: identity,
                allowsDirectoryContentChanges: allowsDirectoryContentChanges
            ) else {
                excluded.append(target)
                continue
            }

            do {
                try fm.trashItem(at: targetURL, resultingItemURL: nil)
                succeeded.append(target)
            } catch {
                let trashFailure = Failure(url: targetURL, error: error)
                logger.warning(
                    "FileManager trash failed path=\(trashFailure.path, privacy: .private) domain=\(trashFailure.domain, privacy: .public) code=\(trashFailure.code) message=\(trashFailure.message, privacy: .private)"
                )

                // 폴백 직전에도 같은 항목인지 다시 확인한다.
                guard isIdentityCurrent(
                    target,
                    url: url,
                    identity: identity,
                    allowsDirectoryContentChanges: allowsDirectoryContentChanges
                ) else {
                    excluded.append(target)
                    continue
                }

                if let workspaceFailure = await recycleUsingWorkspace(targetURL) {
                    logger.error(
                        "NSWorkspace recycle failed path=\(workspaceFailure.path, privacy: .private) domain=\(workspaceFailure.domain, privacy: .public) code=\(workspaceFailure.code) message=\(workspaceFailure.message, privacy: .private)"
                    )
                    failed.append(target)
                    if firstFailure == nil { firstFailure = workspaceFailure }
                } else {
                    succeeded.append(target)
                }
            }
        }

        return Outcome(
            succeeded: succeeded,
            failed: failed,
            excluded: excluded,
            firstFailure: firstFailure
        )
    }

    // MARK: - 내부

    nonisolated private static func isIdentityCurrent<Item>(
        _ target: Item,
        url: (Item) -> URL,
        identity: (Item) -> FileIdentitySnapshot?,
        allowsDirectoryContentChanges: (Item) -> Bool
    ) -> Bool {
        guard let snapshot = identity(target) else { return false }
        return snapshot.matchesCurrentItem(
            at: url(target),
            allowDirectoryContentChanges: allowsDirectoryContentChanges(target)
        )
    }

    /// 성공 시 nil, 실패 시 오류 정보를 반환합니다. AppKit 접근이므로 MainActor에서 수행합니다.
    @MainActor
    private static func recycleUsingWorkspace(_ url: URL) async -> Failure? {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error {
                    continuation.resume(returning: Failure(url: url, error: error))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
