//
//  StoreManager.swift
//  TriClean
//
//  Created by Assistant on 2/7/26.
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

    private let enableGrandfathering: Bool = false
    private let productID = "com.triclean.lifetime"

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPurchased: Bool = false
    @Published private(set) var hasLoadedPurchaseState: Bool = false
    @Published var isLoading: Bool = false
    @Published private(set) var isFetchingProducts: Bool = false
    @Published private(set) var productsErrorMessage: String? = nil

    #if DEBUG
    /// DEBUG 전용: 실제 StoreKit 없이 구매 상태를 강제 설정합니다.
    /// UserDefaults에 저장되어 앱 재시작 후에도 유지됩니다.
    @Published var debugPurchaseOverride: Bool = UserDefaults.standard.bool(forKey: "debug.purchaseOverride") {
        didSet {
            UserDefaults.standard.set(debugPurchaseOverride, forKey: "debug.purchaseOverride")
            isPurchased = debugPurchaseOverride
        }
    }
    #endif

    init() {
        updatesTask = listenForTransactions()
        Task {
            async let statusTask: Void  = updatePurchasedStatus()
            async let productsTask: Void = loadProducts()
            _ = await (statusTask, productsTask)
        }
    }

    deinit { updatesTask?.cancel() }

    func purchase() async throws {
        guard let product = products.first else { return }
        isLoading = true
        defer { isLoading = false }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try verified(verification)
            await transaction.finish()
            await updatePurchasedStatus()
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        await updatePurchasedStatus()
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

    private func listenForTransactions() -> Task<Void, Never> {
        let productID = self.productID
        return Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            for await result in Transaction.updates {
                do {
                    let transaction = try self.verified(result)
                    await transaction.finish()
                    if transaction.productID == productID {
                        await self.updatePurchasedStatus()
                    }
                } catch { continue }
            }
        }
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

    private func updatePurchasedStatus() async {
        defer { hasLoadedPurchaseState = true }
        isPurchased = false

        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.purchaseOverride") {
            isPurchased = true
            return
        }
        #endif

        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try verified(result)
                if transaction.productID == productID {
                    isPurchased = true
                    return
                }
            } catch { continue }
        }

        if enableGrandfathering {
            do {
                let appTransaction = try verified(await AppTransaction.shared)
                if let v = Version.parse(appTransaction.originalAppVersion),
                   v <= Version(major: 1, minor: 0, patch: 0) {
                    isPurchased = true
                    return
                }
            } catch {}
        }
    }

    nonisolated private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):       return safe
        case .unverified(_, let error): throw error
        }
    }
}
