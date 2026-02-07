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

    // ⚠️ App Store Connect에서 생성한 '비소모성' 제품 ID를 여기에 입력하세요.
    private let productID = "com.triclean.lifetime"
    
    @Published private(set) var products: [Product] = []
    @Published private(set) var isPurchased: Bool = false
    @Published private(set) var hasLoadedPurchaseState: Bool = false
    @Published var isLoading: Bool = false
    @Published private(set) var isFetchingProducts: Bool = false
    @Published private(set) var productsErrorMessage: String? = nil    
    
    init() {
        Task {
            // ✅ 둘 다 네트워크를 탈 수 있으니 병렬로 시작(한쪽 지연이 다른쪽 UI를 막지 않게)
            async let _ = updatePurchasedStatus()
            async let _ = loadProducts()
            _ = await ((), ())
        }
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

    func restore() async {
        try? await AppStore.sync()
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

    private func updatePurchasedStatus() async {
    defer { self.hasLoadedPurchaseState = true }

    // 1. 현재 인앱 결제 내역(Pro 버전) 확인
    for await result in Transaction.currentEntitlements {
        do {
            let transaction = try verified(result)
            if transaction.productID == productID {
                self.isPurchased = true
                return
            }
        } catch {
            // unverified transaction은 구매로 인정하지 않음
            continue
        }
    }

    // 2. [중요] 기존 유료 앱 구매자 보호 (Grandfathering)
    do {
        let appTransaction = try verified(await AppTransaction.shared)
        let version = appTransaction.originalAppVersion

        // ⚠️ 무료 전환 업데이트 버전이 2.0이라면, "2.0" 미만 버전은 기존 구매자로 처리
        // 문자열 비교보다는 Build Number(Int) 비교가 안전할 수 있습니다.
        // 예: 현재 버전이 "1.0.0" 또는 "1.0" 또는 "1"이라면 구매자로 인정
        if version == "1.0.0" || version == "1.0" || version == "1" {
            self.isPurchased = true
            return
        }
    } catch {
        // unverified AppTransaction(또는 실패)은 무시
    }

        self.isPurchased = false
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified(_, let error):
            throw error
        }
    }

}
