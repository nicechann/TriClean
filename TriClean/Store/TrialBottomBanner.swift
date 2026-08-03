//
//  TrialBottomBanner.swift
//  TriClean
//
//  Created by nicechann on 2/7/26.
//

import SwiftUI

struct TrialBottomBanner: View {
    let daysRemaining: Int
    let onBuyTap: () -> Void
    
    // 7일 기준 진행률 계산 (7일 남음 = 0%, 0일 남음 = 100% 혹은 반대)
    // 스크린샷의 주황색 바는 "시간이 얼마나 지났는지" 혹은 "남은 시간"을 의미합니다.
    // 여기서는 "지난 시간"을 채우는 방식으로 구현합니다 (7일 중 1일 지남 -> 조금 채워짐).
    private var progress: Double {
        let totalDays: Double = 7.0
        let elapsed = totalDays - Double(daysRemaining)
        return max(0, min(elapsed / totalDays, 1.0))
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // 1. 텍스트 정보 (무료 체험 / 7일 남음)
            HStack {
                Text("trial.bottom.title".localized)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                
                Spacer()
                
                Text("trial.bottom.days_left".localized(with: daysRemaining))
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.orange)
            }
            
            // 2. 진행 바 (주황색)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // 배경 (어두운 회색)
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 6)
                    
                    // 채워지는 부분 (주황색 + 끝에 점)
                    ZStack(alignment: .trailing) {
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: max(10, geo.size.width * progress))
                        
                        // 끝에 달린 점
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 10, height: 10)
                            .offset(x: 4) // 살짝 오른쪽으로
                    }
                    .frame(height: 6)
                }
            }
            .frame(height: 10) // GeometryReader 높이 확보
            
            // 3. 구매 버튼
            Button {
                onBuyTap()
            } label: {
                HStack {
                    Image(systemName: "lock.open.fill")
                    Text("trial.bottom.buy_now".localized)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)
        }
        .padding(16)
        // 배너 전체 배경 (아주 어두운 회색)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}
