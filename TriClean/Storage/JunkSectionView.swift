//
//  JunkSectionView.swift
//  TriClean
//
//  StorageView 안에 임베드되는 정크 파일 탐지 섹션
//  ~/Library 경로 선택 → 카테고리별 정크 용량 표시 → 원클릭 정리
//

import SwiftUI

struct JunkSectionView: View {
    @ObservedObject var viewModel: JunkScannerViewModel
    @State private var showCleanConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "trash.circle")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("junk.section.title".localized)
                        .font(.title3.bold())
                    Text("junk.section.subtitle".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.isScanning {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.scanProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if viewModel.libraryURL != nil {
                    Button {
                        viewModel.scan()
                    } label: {
                        Label("junk.section.scan".localized, systemImage: "magnifyingglass")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: viewModel.libraryURL == nil ? "xmark.circle" : "checkmark.circle")
                    .foregroundStyle(viewModel.libraryURL == nil ? Color.secondary : Color.green)
                    .frame(width: 16)

                if let url = viewModel.libraryURL {
                    Text(url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("junk.section.select_library_hint".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(viewModel.libraryURL == nil ? "junk.section.select_library".localized : "common.change".localized) {
                    viewModel.selectLibraryFolder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if viewModel.libraryURL != nil && !viewModel.isScanning && !viewModel.hasResults {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("junk.section.ready_title".localized)
                            .font(.caption.bold())
                        Text("junk.section.ready_desc".localized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            if viewModel.hasResults {
                HStack(spacing: 16) {
                    Label {
                        Text("junk.section.found".localized(with: viewModel.totalJunkString))
                            .font(.caption.bold())
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }

                    Label {
                        Text("junk.section.selected".localized(with: viewModel.selectedJunkString))
                            .font(.caption.bold())
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        showCleanConfirm = true
                    } label: {
                        Label("junk.section.clean".localized, systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(viewModel.selectedJunkBytes == 0)
                }
                .padding(.top, 4)

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(viewModel.results) { result in
                        junkCategoryCard(result)
                    }
                }

                if let date = viewModel.lastScanDate {
                    Text("junk.section.last_scan".localized(with: date.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .alert("junk.section.alert.title".localized, isPresented: $showCleanConfirm) {
            Button("common.move_to_trash".localized, role: .destructive) {
                viewModel.cleanSelected()
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("junk.section.alert.message".localized(with: viewModel.selectedJunkString))
        }
    }

    private func junkCategoryCard(_ result: JunkScanResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.category.icon)
                .font(.title3)
                .foregroundStyle(result.category.riskLevel.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.category.name)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(result.totalString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(result.category.riskLevel.label)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(result.category.riskLevel.color.opacity(0.15))
                )
                .foregroundStyle(result.category.riskLevel.color)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .help(result.category.description)
    }
}
