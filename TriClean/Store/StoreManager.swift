//
//  StoreManager.swift
//  TriClean
//
//  Created by Assistant on 2/7/26.
//
//  ✅ [수정 v3]
//   - listenForTransactions의 Task.detached 제거 → 일반 Task로 변경.
//     (@MainActor 클래스이므로 Task {}는 메인 액터에 자동 격리되며,
//      StoreKit 2 권장 패턴과도 일치.)
//   - deinit 제거 — 싱글톤이라 호출되지 않으며 @MainActor 격리 불일치를 유발하던 코드.
//     앱 종료 시 Task는 자동 취소됨.
//   - debugPurchaseOverride의 didSet에서 외부 동기화 명확화.
//

import Foundation
import StoreKit
import Combine
import os.log

private let storeLogger = Logger(subsystem: "com.nicechann.TriClean", category: "Store")

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()
    private var updatesTask: Task<Void, Never>?
    private var purchaseStateGeneration: UInt = 0

    private let enableGrandfathering: Bool = false
    private let productID = "com.triclean.lifetime"

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPurchased: Bool = false
    @Published private(set) var hasLoadedPurchaseState: Bool = false
    @Published var isLoading: Bool = false
    @Published private(set) var isFetchingProducts: Bool = false
    @Published private(set) var productsErrorMessage: String? = nil

    #if DEBUG
    /// DEBUG 전용: 실제 StoreKit 상태와 관계없이 Free(false) / Pro(true)를 강제합니다.
    /// UserDefaults에 저장되어 앱 재시작 후에도 유지됩니다.
    @Published var debugPurchaseOverride: Bool = UserDefaults.standard.bool(forKey: "debug.purchaseOverride") {
        didSet {
            UserDefaults.standard.set(debugPurchaseOverride, forKey: "debug.purchaseOverride")
            purchaseStateGeneration &+= 1
            isPurchased = debugPurchaseOverride
            hasLoadedPurchaseState = true
        }
    }
    #endif

    init() {
        // 앱 밖(App Store/리딤 URL)에서 완료된 Offer Code 거래를 놓치지 않도록
        // updates 리스너를 가장 먼저 등록합니다.
        updatesTask = listenForTransactions()

        Task {
            // 상품 정보 로드는 구매 상태 복구와 독립적이므로 병렬로 진행합니다.
            async let productsTask: Void = loadProducts()

            // 앱이 종료되어 있던 동안 생성된 미처리 거래를 먼저 복구합니다.
            // Apple은 앱 시작 시 currentEntitlements와 unfinished를 모두 확인하도록 안내합니다.
            let recoveredUnfinishedPurchase = await processUnfinishedTransactions()
            _ = await updatePurchasedStatus(fallbackPurchased: recoveredUnfinishedPurchase)

            _ = await productsTask
        }
    }

    // ✅ [수정] deinit 제거.
    //   - StoreManager는 .shared 싱글톤이라 deinit이 실제로 호출되지 않음.
    //   - @MainActor 클래스의 deinit은 nonisolated → updatesTask 접근 시 Swift 6 경고.
    //   - 앱 종료 시 Task는 시스템에 의해 자동 정리됨.

    func purchase() async throws {
        guard !isLoading else { return }
        // ✅ [수정] 조용히 return하면 상품 로드 실패 시 버튼이 반응 없는 것처럼 보인다.
        guard let product = products.first else { throw StoreError.productUnavailable }
        isLoading = true
        defer { isLoading = false }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try verified(verification)
            guard transaction.productID == productID else {
                storeLogger.error(
                    "구매 결과 Product ID 불일치: expected=\(self.productID, privacy: .public), actual=\(transaction.productID, privacy: .public)"
                )
                throw StoreError.productUnavailable
            }

            // 구매 콘텐츠(Lifetime Access)를 먼저 반영한 뒤 거래를 finish합니다.
            // finish를 먼저 호출하면 외부 거래 처리 시점에 UI 상태 갱신이 늦어질 수 있습니다.
            publishPurchaseState(true)
            await transaction.finish()
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restore() async throws {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        try await AppStore.sync()

        // App Store 밖에서 Offer Code를 Redeem한 거래가 unfinished에 남아 있을 수 있으므로
        // sync 직후 미처리 거래를 먼저 회수한 다음 currentEntitlements와 합쳐 판정합니다.
        let recoveredUnfinishedPurchase = await processUnfinishedTransactions()
        let restored = await updatePurchasedStatus(fallbackPurchased: recoveredUnfinishedPurchase)

        guard restored else {
            throw StoreError.noPurchaseToRestore
        }
    }

    private func loadProducts() async {
        isFetchingProducts = true
        productsErrorMessage = nil
        defer { isFetchingProducts = false }

        do {
            let fetched = try await Product.products(for: [productID])
            self.products = fetched
            if fetched.isEmpty {
                // ✅ [수정] 하드코딩 한국어 → localized 키로 교체
                self.productsErrorMessage = "store.error.product_not_found".localized
            }
        } catch {
            self.products = []
            // ✅ [수정] 하드코딩 한국어 → localized 키로 교체
            self.productsErrorMessage = "store.error.load_failed_detail".localized(with: error.localizedDescription)
            storeLogger.error("상품 로드 실패: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reloadProducts() async {
        await loadProducts()
    }

    // ✅ [수정] Task.detached → 일반 Task.
    //   - @MainActor 클래스 내부의 Task {}는 메인 액터에 격리되어 self 호출이 안전.
    //   - StoreKit 2의 Transaction.updates는 AsyncSequence이므로 어떤 컨텍스트든 정상 동작.
    //   - 별도 스레드가 필요하지 않은데 detached로 빼면 격리/await 부담만 늘어남.
    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try self.verified(result)

                    // 이 StoreManager가 소유한 Lifetime 상품만 처리합니다.
                    // 다른 상품의 거래를 여기서 임의로 finish하면 해당 상품의 전달 로직이
                    // 실행되기 전에 거래가 완료될 수 있으므로 건드리지 않습니다.
                    guard transaction.productID == self.productID else {
                        storeLogger.notice(
                            "처리 대상이 아닌 거래 건너뜀: productID=\(transaction.productID, privacy: .public)"
                        )
                        continue
                    }

                    if transaction.revocationDate == nil {
                        // App Store/Offer Code 등 앱 밖에서 발생한 정상 거래는
                        // currentEntitlements 재조회보다 거래 자체를 우선 반영해 즉시 잠금 해제합니다.
                        self.publishPurchaseState(true)
                    } else {
                        // 환불/취소된 거래는 현재 entitlement를 다시 계산합니다.
                        await self.updatePurchasedStatus()
                    }

                    // 서비스 반영 후에만 거래를 완료합니다.
                    await transaction.finish()
                } catch {
                    storeLogger.warning("Transaction verification failed: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
        }
    }

    /// 앱이 실행되지 않는 동안 생성된 미처리 StoreKit 거래를 복구합니다.
    /// 특히 App Store에서 Offer Code를 교환한 뒤 앱을 처음 실행하는 경로를 보완합니다.
    /// - Returns: 유효한 Lifetime 거래를 하나 이상 복구했는지 여부.
    private func processUnfinishedTransactions() async -> Bool {
        #if DEBUG
        // DEBUG에서 Free/Pro를 명시적으로 강제한 경우 테스트 상태를 StoreKit이 덮지 않게 합니다.
        if UserDefaults.standard.object(forKey: "debug.purchaseOverride") != nil {
            return false
        }
        #endif

        var recoveredPurchase = false

        for await result in Transaction.unfinished {
            do {
                let transaction = try verified(result)

                guard transaction.productID == productID else {
                    storeLogger.notice(
                        "처리 대상이 아닌 unfinished 거래 건너뜀: productID=\(transaction.productID, privacy: .public)"
                    )
                    continue
                }

                if transaction.revocationDate == nil {
                    recoveredPurchase = true
                    publishPurchaseState(true)
                    storeLogger.info(
                        "미처리 Lifetime 거래 복구: transactionID=\(transaction.id, privacy: .public)"
                    )
                } else {
                    storeLogger.info(
                        "취소/환불된 미처리 Lifetime 거래 정리: transactionID=\(transaction.id, privacy: .public)"
                    )
                }

                // Lifetime Access 반영(또는 취소 상태 확인) 후 거래를 완료합니다.
                await transaction.finish()
            } catch {
                storeLogger.warning(
                    "Unfinished transaction verification failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return recoveredPurchase
    }

    private struct Version: Comparable {
        let major: Int; let minor: Int; let patch: Int

        static func parse(_ raw: String) -> Version? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix  = trimmed.prefix { $0.isNumber || $0 == "." }
            guard !prefix.isEmpty else { return nil }
            let parts = prefix.split(separator: ".").compactMap { Int($0) }
            return Version(
                major: parts.count > 0 ? parts[0] : 0,
                minor: parts.count > 1 ? parts[1] : 0,
                patch: parts.count > 2 ? parts[2] : 0
            )
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

    /// 구매 상태 갱신은 여러 경로(초기화·구매·복원·Transaction.updates)에서
    /// 동시에 요청될 수 있습니다. 세대 번호로 오래된 결과가 최신 상태를 덮지 않게 합니다.
    /// `fallbackPurchased`는 방금 검증한 unfinished 거래처럼 currentEntitlements 반영보다
    /// 한 박자 빠르게 확인된 구매를 이번 판정에 보존하기 위한 값입니다.
    @discardableResult
    private func updatePurchasedStatus(fallbackPurchased: Bool = false) async -> Bool {
        purchaseStateGeneration &+= 1
        let generation = purchaseStateGeneration
        let resolved = await resolvePurchasedStatus()

        // 조회 중 Transaction.updates 등 더 최신 이벤트가 상태를 갱신했다면
        // 오래된 조회 결과를 덮지 않고 현재 최신 상태를 그대로 사용합니다.
        guard generation == purchaseStateGeneration else { return isPurchased }

        isPurchased = resolved || fallbackPurchased
        hasLoadedPurchaseState = true
        return isPurchased
    }

    /// 이미 검증을 마친 거래/복원 결과를 즉시 UI 상태에 반영합니다.
    /// 진행 중이던 이전 entitlement 조회 결과가 뒤늦게 덮지 못하도록 세대도 함께 올립니다.
    private func publishPurchaseState(_ purchased: Bool) {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "debug.purchaseOverride") != nil {
            isPurchased = UserDefaults.standard.bool(forKey: "debug.purchaseOverride")
            hasLoadedPurchaseState = true
            purchaseStateGeneration &+= 1
            return
        }
        #endif

        purchaseStateGeneration &+= 1
        isPurchased = purchased
        hasLoadedPurchaseState = true
    }

    private func resolvePurchasedStatus() async -> Bool {
        #if DEBUG
        // ✅ [수정] 기존에는 DEBUG에서 Transaction.currentEntitlements를 아예 조회하지 않아
        //   StoreKit 구성 파일로 구매/복원 플로우를 검증할 수 없었다.
        //   (restore()가 항상 noPurchaseToRestore를 던짐)
        //   override가 **명시적으로 설정된 경우에만** 우선하도록 바꾸고,
        //   그 외에는 릴리스와 동일한 경로를 타게 한다.
        if UserDefaults.standard.object(forKey: "debug.purchaseOverride") != nil {
            return UserDefaults.standard.bool(forKey: "debug.purchaseOverride")
        }
        #endif

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try verified(result)
                guard transaction.productID == productID else {
                    storeLogger.notice(
                        "현재 entitlement의 Product ID 불일치: expected=\(self.productID, privacy: .public), actual=\(transaction.productID, privacy: .public)"
                    )
                    continue
                }

                // currentEntitlements는 원칙적으로 현재 유효한 권한만 반환하지만,
                // 환불/취소 상태를 한 번 더 방어적으로 확인합니다.
                if transaction.revocationDate == nil {
                    return true
                }
            } catch {
                storeLogger.warning(
                    "Current entitlement verification failed: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
        }

        if enableGrandfathering {
            do {
                let appTransaction = try verified(await AppTransaction.shared)
                if let v = Version.parse(appTransaction.originalAppVersion),
                   v <= Version(major: 1, minor: 0, patch: 0) {
                    return true
                }
            } catch {}
        }

        return false
    }

    nonisolated private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):       return safe
        case .unverified(_, let error): throw error
        }
    }
}

/// 구매 흐름에서 사용자에게 노출되는 오류.
///
/// ⚠️ `nonisolated`: `Error` 값은 `throw`되어 nonisolated 경계를 넘을 수 있다.
///   기본 액터 격리 때문에 `errorDescription`이 MainActor로 추론되면
///   `LocalizedError` conformance 전체가 격리되어 Swift 6에서 에러가 된다.
nonisolated enum StoreError: LocalizedError, Sendable {
    case productUnavailable
    case noPurchaseToRestore

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return "store.error.product_unavailable".localized
        case .noPurchaseToRestore:
            return "store.error.no_purchase_to_restore".localized
        }
    }
}
