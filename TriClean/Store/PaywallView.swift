//
//  PaywallView.swift
//  TriClean
//
//  Created by Assistant on 2/7/26.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storeManager: StoreManager
    @State private var purchaseErrorMessage: String? = nil
    @State private var showPurchaseErrorAlert: Bool = false

    let allowDismiss: Bool

    init(allowDismiss: Bool = true) {
        self.allowDismiss = allowDismiss
    }

    var body: some View {
        VStack(spacing: 24) {
            // 1. 상단 아이콘 및 타이틀
            VStack(spacing: 12) {
                Image(systemName: "star.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.yellow)
                    .shadow(color: .orange.opacity(0.5), radius: 10, x: 0, y: 0)

                Text("paywall.title".localized)
                    .font(.system(size: 28, weight: .bold))

                Text("paywall.subtitle".localized)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)

            // 2. 기능 목록
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(icon: "sparkles",         title: "paywall.feat.memory".localized, desc: "paywall.feat.memory_desc".localized)
                FeatureRow(icon: "internaldrive.fill", title: "paywall.feat.disk".localized,   desc: "paywall.feat.disk_desc".localized)
                FeatureRow(icon: "app.fill",          title: "paywall.feat.apps".localized,   desc: "paywall.feat.apps_desc".localized)
                FeatureRow(icon: "clock.fill",        title: "paywall.feat.auto".localized,   desc: "paywall.feat.auto_desc".localized)
            }
            .padding(.vertical, 10)

            Spacer()

            // 3. 하단 버튼 영역
            VStack(spacing: 12) {
                if storeManager.isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(height: 50)

                } else if storeManager.isFetchingProducts {
                    ProgressView("store.status.loading_products".localized)
                        .controlSize(.large)
                        .frame(height: 50)

                } else if storeManager.products.first == nil {
                    VStack(spacing: 8) {
                        Text(storeManager.productsErrorMessage ?? "store.error.load_failed".localized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        Button("store.btn.retry".localized) {
                            Task { await storeManager.reloadProducts() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                } else {
                    if let product = storeManager.products.first {
                        Button {
                            Task {
                                do {
                                    try await storeManager.purchase()
                                } catch {
                                    purchaseErrorMessage = error.localizedDescription
                                    showPurchaseErrorAlert = true
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if storeManager.isLoading {
                                    ProgressView().controlSize(.small)
                                }
                                Text("paywall.btn.buy_format".localized(with: product.displayPrice))
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.blue)
                        .disabled(storeManager.isLoading)
                    }
                }

                // Restore
                Button {
                    Task {
                        do {
                            try await storeManager.restore()
                        } catch {
                            purchaseErrorMessage = error.localizedDescription
                            showPurchaseErrorAlert = true
                        }
                    }
                } label: {
                    Text("paywall.btn.restore".localized)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(storeManager.isLoading)

                // 나중에 하기 (시트에서만)
                if allowDismiss {
                    Button { dismiss() } label: {
                        Text("paywall.btn.later".localized)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                // 하단 링크
                HStack(spacing: 20) {
                    Link("paywall.link.privacy".localized, destination: URL(string: "https://nicechann.github.io/TriClean-Support/privacy")!)
                    Link("paywall.link.terms".localized,   destination: URL(string: "https://nicechann.github.io/TriClean-Support/terms")!)
                }
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(.top, 4)
            }
        }
        .padding(30)
        .frame(width: 450, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
        .onAppear {
            if allowDismiss, storeManager.isPurchased { dismiss() }
        }
        .onChange(of: storeManager.isPurchased) { newValue in
            if allowDismiss, newValue { dismiss() }
        }
        // ✅ [수정] 하드코딩 한국어 → localized 키로 교체
        .alert("paywall.error.title".localized, isPresented: $showPurchaseErrorAlert) {
            Button("common.confirm".localized, role: .cancel) { }
        } message: {
            Text(purchaseErrorMessage ?? "paywall.error.unknown".localized)
        }
    }
}

// 기능 목록 한 줄 컴포넌트
private struct FeatureRow: View {
    let icon: String
    let title: String
    let desc: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
