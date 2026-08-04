//
//  PaywallView.swift
//  TriClean
//
//  Created by Assistant on 2/7/26.
//

import SwiftUI
import StoreKit
import AppKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storeManager: StoreManager
    @State private var purchaseErrorMessage: String? = nil
    @State private var showPurchaseErrorAlert: Bool = false

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

                Text("paywall.free_mode.notice".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
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

                Button { dismiss() } label: {
                    Text("paywall.btn.later".localized)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                // 하단 링크
                HStack(spacing: 20) {
                    if let privacyURL = AppLinks.privacyPolicy {
                        Link("paywall.link.privacy".localized, destination: privacyURL)
                    }
                    if let termsURL = AppLinks.termsOfUse {
                        Link("paywall.link.terms".localized, destination: termsURL)
                    }
                }
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(.top, 4)
            }
        }
        .padding(30)
        // ✅ 다국어 장문에서도 콘텐츠가 잘리지 않도록 고정 높이 대신 최소 높이만 지정
        .frame(width: 450)
        .frame(minHeight: 650)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
        .onAppear {
            if storeManager.isPurchased { dismiss() }
        }
        .onChange(of: storeManager.isPurchased) { newValue in
            if newValue { dismiss() }
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
