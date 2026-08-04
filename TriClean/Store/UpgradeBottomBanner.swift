//
//  UpgradeBottomBanner.swift
//  TriClean
//
//  Created by nicechann on 2/7/26.
//

import SwiftUI

struct UpgradeBottomBanner: View {
    let onBuyTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 3) {
                Text("upgrade.bottom.title".localized)
                    .font(.subheadline.bold())
                Text("upgrade.bottom.desc".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button("upgrade.bottom.buy".localized) {
                onBuyTap()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
