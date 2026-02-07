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

    /// true: 시트/모달 등에서 "나중에"로 닫을 수 있음
    /// false: 체험 만료 등 루트 Paywall에서는 닫기 버튼을 숨김
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
                
                Text("TriClean Premium")
                    .font(.system(size: 28, weight: .bold))
                
                Text("모든 기능을 무제한으로 사용하세요")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            
            // 2. 기능 목록 (Features)
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(icon: "sparkles", title: "무제한 메모리 정리", desc: "원하는 만큼 메모리를 정리하세요")
                FeatureRow(icon: "internaldrive.fill", title: "고급 디스크 분석", desc: "대용량 파일과 폴더를 빠르게 찾으세요")
                FeatureRow(icon: "app.fill", title: "앱 심화 관리", desc: "불필요한 파일까지 완벽하게 정리")
                FeatureRow(icon: "clock.fill", title: "자동 정기 정리", desc: "설정된 시간에 자동으로 정리")
            }
            .padding(.vertical, 10)
            
            Spacer()
            
            // 3. 하단 버튼 영역
            VStack(spacing: 12) {
                // ✅ 구매 진행 중
                if storeManager.isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(height: 50)
                }
                // ✅ 상품 로딩 중
                else if storeManager.isFetchingProducts {
                    ProgressView("상품 정보를 불러오는 중…")
                        .controlSize(.large)
                        .frame(height: 50)
                }
                // ✅ 상품 로딩 실패/빈 배열
                else if storeManager.products.first == nil {
                    VStack(spacing: 8) {
                        Text(storeManager.productsErrorMessage ?? "상품 정보를 불러올 수 없습니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        Button("다시 시도") {
                            Task { await storeManager.reloadProducts() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                // ✅ 정상: 가격 버튼
                else {
                    // 구매 버튼
                    if let product = storeManager.products.first {
                        Button {
                            Task { try? await storeManager.purchase() }
                        } label: {
                            Text("지금 구매 (\(product.displayPrice))")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.blue)
                    }
                }
                // Restore (비소모성 IAP 필수)
                Button {
                    Task { await storeManager.restore() }
                } label: {
                    Text("구매 복원")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                // 나중에 하기 버튼 (시트에서만 표시)
                if allowDismiss {
                    Button {
                        dismiss()
                    } label: {
                        Text("나중에")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                
                // 하단 링크
                HStack(spacing: 20) {
                    Link("개인정보", destination: URL(string: "https://nicechann.github.io/TriClean-Support/privacy")!)
                    Link("이용약관", destination: URL(string: "https://nicechann.github.io/TriClean-Support/terms")!)
                }
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(.top, 4)
            }
        }
        .padding(30)
        .frame(width: 450, height: 650)
        // 배경을 어둡게 처리 (스크린샷 느낌)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // 시트로 열렸는데 이미 구매 상태라면 즉시 닫기
            if allowDismiss, storeManager.isPurchased {
                dismiss()
            }
        }
        .onChange(of: storeManager.isPurchased) { newValue in
            // 구매 완료 시, 시트(allowDismiss=true)라면 자동 닫기
            if allowDismiss, newValue {
                dismiss()
            }
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
                Text(title)
                    .font(.headline)
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
