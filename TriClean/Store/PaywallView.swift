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
        VStack(spacing: 20) {
            // 큰 글자·긴 번역에서 시트가 화면보다 길어지면 구매·복원 버튼이 밀려났다.
            // 소개 영역만 스크롤하고 버튼 영역은 항상 보이게 둔다.
            ScrollView(.vertical) {
                introSection
            }

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
                            .appFont(.subheadline)
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
                                    .appFont(.headline)
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
                        .appFont(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(storeManager.isLoading)

                Button { dismiss() } label: {
                    Text("paywall.btn.later".localized)
                        .appFont(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

                // 하단 링크
                HStack(spacing: 20) {
                    if let privacyURL = AppLinks.privacyPolicy {
                        Link("paywall.link.privacy".localized, destination: privacyURL)
                    }
                    if let termsURL = AppLinks.termsOfUse {
                        Link("paywall.link.terms".localized, destination: termsURL)
                    }
                }
                .appFont(.caption)
                .foregroundStyle(.blue)
                .padding(.top, 4)
            }
        }
        .padding(30)
        // ⚠️ 세로 고정(`.fixedSize(horizontal: false, vertical: true)`)을 쓰지 않는다.
        //    본문 전체 높이를 강제해 작은 화면·큰 글자에서 시트가 화면을 넘었다.
        //    idealHeight로 평소 크기를 주고, 모자라면 위 ScrollView가 줄어든다.
        .frame(width: 450)
        .frame(minHeight: 520, idealHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if storeManager.isPurchased { dismiss() }
        }
        .onValueChange(of: storeManager.isPurchased) { newValue in
            if newValue { dismiss() }
        }
        // ✅ [수정] 하드코딩 한국어 → localized 키로 교체
        .alert("paywall.error.title".localized, isPresented: $showPurchaseErrorAlert) {
            Button("common.confirm".localized, role: .cancel) { }
        } message: {
            Text(purchaseErrorMessage ?? "paywall.error.unknown".localized)
        }
    }

    // 1~2. 소개(아이콘·타이틀·무료 범위 안내)와 기능 목록
    private var introSection: some View {
        VStack(spacing: 24) {
            // 1. 상단 아이콘 및 타이틀
            VStack(spacing: 12) {
                Image(systemName: "star.fill")
                    .appIconFont(64)
                    .foregroundStyle(.yellow)
                    .shadow(color: .orange.opacity(0.5), radius: 10, x: 0, y: 0)

                Text("paywall.title".localized)
                    .appFont(size: 28, weight: .bold)

                Text("paywall.subtitle".localized)
                    .appFont(.body)
                    .foregroundStyle(.secondary)

                Text("paywall.free_mode.notice".localized)
                    .appFont(.callout)
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
        }
        .frame(maxWidth: .infinity)
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
                .appFont(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).appFont(.headline)
                Text(desc).appFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
