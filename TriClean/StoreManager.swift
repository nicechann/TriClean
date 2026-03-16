//
//  StoreManager.swift
//  TriClean
//
//  Created by Assistant on 2/7/26.
//

import Foundation
import StoreKit
import Combine

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()
    private var updatesTask: Task<Void, Never>?
    /// 기존 유료 앱 구매자 보호(Grandfathering) 사용 여부
    private let enableGrandfathering: Bool = false
    // ⚠️ App Store Connect에서 생성한 '비소모성' 제품 ID를 여기에 입력하세요.
    private let productID = "com.triclean.lifetime"
    
    @Published private(set) var products: [Product] = []
    @Published private(set) var isPurchased: Bool = false
    @Published private(set) var hasLoadedPurchaseState: Bool = false
    @Published var isLoading: Bool = false
    @Published private(set) var isFetchingProducts: Bool = false
    @Published private(set) var productsErrorMessage: String? = nil    

    init() {
        updatesTask = listenForTransactions()

        Task {
            // ✅ 둘 다 네트워크를 탈 수 있으니 병렬로 시작(한쪽 지연이 다른쪽 UI를 막지 않게)
            async let statusTask: Void = updatePurchasedStatus()
            async let productsTask: Void = loadProducts()
            _ = await (statusTask, productsTask)
        }
    }

    deinit {
        updatesTask?.cancel()
    }

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
            let products = try await Product.products(for: [productID])
            self.products = products
            if products.isEmpty {
                self.productsErrorMessage = "상품을 찾지 못했습니다. Product ID 또는 StoreKit 설정을 확인하세요."
            }
        } catch {
            self.products = []
            self.productsErrorMessage = "상품 로드 실패: \(error.localizedDescription)"
            print("상품 로드 실패: \(error)")
        }
    }

    // ✅ Paywall에서 '다시 시도' 버튼용
    func reloadProducts() async {
        await loadProducts()
    }

    private func listenForTransactions() -> Task<Void, Never> {
        let productID = self.productID

        // Transaction.updates는 앱 실행 중 결제/복원 등의 변경을 스트림으로 전달합니다.
        // 상태 변경 시점에 isPurchased를 동기화해 Paywall/메뉴 UI 반영이 늦어지는 것을 줄입니다.
        return Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            for await result in Transaction.updates {
                do {
                    let transaction = try self.verified(result)
                    await transaction.finish()

                    if transaction.productID == productID {
                        await self.updatePurchasedStatus()
                    }
                } catch {
                    // unverified transaction은 무시
                    continue
                }
            }
        }
    }

    private struct Version: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func parse(_ raw: String) -> Version? {
            // 예: "1", "1.0", "1.0.0", "1.0.0 (100)" 등에서 숫자/점 prefix만 추출
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = trimmed.prefix { $0.isNumber || $0 == "." }
            guard !prefix.isEmpty else { return nil }

            let parts = prefix.split(separator: ".").compactMap { Int($0) }
            let major = parts.count > 0 ? parts[0] : 0
            let minor = parts.count > 1 ? parts[1] : 0
            let patch = parts.count > 2 ? parts[2] : 0
            return Version(major: major, minor: minor, patch: patch)
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

    private func updatePurchasedStatus() async {
        defer { hasLoadedPurchaseState = true }

        // ✅ 중요: 이전 실행/테스트에서 isPurchased가 true였던 값이 남지 않도록
        // 매번 갱신 시작 시 기본을 "미구매"로 리셋
        isPurchased = false

        // 1. 현재 인앱 결제 내역(Pro 버전) 확인
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try verified(result)
                if transaction.productID == productID {
                    isPurchased = true
                    return
                }
            } catch {
                // unverified transaction은 구매로 인정하지 않음
                continue
            }
        }

        // 2. 기존 유료 앱 구매자 보호 (Grandfathering)
        // ⚠️ 기본은 OFF. (현재 유료 구매자가 없으면, 이 로직이 오탐으로 "구매됨"을 만들 수 있음)
        if enableGrandfathering {
            do {
                let appTransaction = try verified(await AppTransaction.shared)
                let originalVersion = appTransaction.originalAppVersion

                // 기존 코드의 "1.0.0 / 1.0 / 1" 조건을 버전 파싱으로 안전하게 확장
                if let v = Version.parse(originalVersion),
                   v <= Version(major: 1, minor: 0, patch: 0) {
                    isPurchased = true
                    return
                }
            } catch {
                // unverified AppTransaction(또는 실패)은 무시
            }
        }
    }

    nonisolated private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified(_, let error):
            throw error
        }
    }

}
