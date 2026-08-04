//
//  JunkSectionView.swift
//  TriClean
//
//  StorageView 안에 임베드되는 정크 파일 탐지 섹션
//  ~/Library 경로 선택 → 카테고리별 정크 용량 표시 → 개별 항목 선택 → 정리
//

import SwiftUI

struct JunkSectionView: View {
    @EnvironmentObject private var storeManager: StoreManager
    @ObservedObject var viewModel: JunkScannerViewModel
    let onUpgradeRequired: () -> Void
    @State private var showCleanConfirm = false
    @State private var expandedCategories: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── 헤더 ──
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

                if viewModel.isScanning || viewModel.isCleaning {
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
                    .disabled(!viewModel.isValidLibraryPath || viewModel.isCleaning)
                }
            }

            // ── 경로 상태 ──
            HStack(spacing: 10) {
                Image(systemName: viewModel.libraryURL == nil
                      ? "xmark.circle"
                      : (viewModel.isValidLibraryPath ? "checkmark.circle" : "exclamationmark.triangle"))
                    .foregroundStyle(viewModel.libraryURL == nil
                                     ? Color.secondary
                                     : (viewModel.isValidLibraryPath ? Color.green : Color.orange))
                    .frame(width: 16)

                if let url = viewModel.libraryURL {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !viewModel.isValidLibraryPath {
                            Text("junk.section.wrong_path_warning".localized)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
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

            // ── 접근 권한 만료 안내 ──
            if viewModel.accessDenied {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("junk.section.access_title".localized)
                            .font(.caption.bold())
                        Text("junk.section.access_desc".localized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("common.change".localized) {
                        viewModel.selectLibraryFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
            }

            // ── 준비 상태 / 잘못된 경로 안내 ──
            if viewModel.libraryURL != nil && !viewModel.isScanning && !viewModel.hasResults && !viewModel.accessDenied {
                HStack(spacing: 10) {
                    Image(systemName: viewModel.isValidLibraryPath ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(viewModel.isValidLibraryPath ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.isValidLibraryPath
                             ? "junk.section.ready_title".localized
                             : "junk.section.wrong_path_title".localized)
                            .font(.caption.bold())
                        Text(viewModel.isValidLibraryPath
                             ? "junk.section.ready_desc".localized
                             : "junk.section.wrong_path_desc".localized)
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

            // ── 스캔 결과 ──
            if viewModel.hasResults {
                // 요약 바
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
                        if storeManager.isPurchased {
                            showCleanConfirm = true
                        } else {
                            onUpgradeRequired()
                        }
                    } label: {
                        Label("junk.section.clean".localized, systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(viewModel.selectedJunkBytes == 0 || viewModel.isScanning || viewModel.isCleaning)
                }
                .padding(.top, 4)

                // 카테고리 목록 (펼치기/접기 가능)
                VStack(spacing: 6) {
                    ForEach(viewModel.results) { result in
                        junkCategoryRow(result)
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
                guard storeManager.isPurchased else {
                    onUpgradeRequired()
                    return
                }
                viewModel.cleanSelected()
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("junk.section.alert.message".localized(with: viewModel.selectedJunkString))
        }
    }

    // MARK: - 카테고리 행 (펼침/접힘)

    private func junkCategoryRow(_ result: JunkScanResult) -> some View {
        let isExpanded = expandedCategories.contains(result.id)
        let selectedCount = result.items.filter(\.isSelected).count

        return VStack(alignment: .leading, spacing: 0) {
            // 카테고리 헤더 (클릭하면 펼침/접힘)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedCategories.remove(result.id)
                    } else {
                        expandedCategories.insert(result.id)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: result.category.icon)
                        .font(.body)
                        .foregroundStyle(result.category.riskLevel.color)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(result.category.name)
                                .font(.caption.bold())
                            Text("\(selectedCount)/\(result.items.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(result.totalString)
                            .font(.caption2.monospacedDigit())
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

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 펼쳤을 때 — 개별 항목 목록
            if isExpanded {
                Divider()
                    .padding(.horizontal, 10)

                // 전체 선택 / 해제
                HStack(spacing: 8) {
                    Button("junk.item.select_all".localized) { viewModel.selectAll(in: result.id) }
                    Button("junk.item.deselect_all".localized) { viewModel.deselectAll(in: result.id) }
                    Spacer()
                    Text(result.category.description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .padding(.horizontal, 12)
                .padding(.top, 6)

                // 항목 목록
                VStack(spacing: 0) {
                    ForEach(result.items.prefix(30)) { item in
                        junkItemRow(item, categoryID: result.id)
                    }
                    if result.items.count > 30 {
                        Text("junk.item.more".localized(with: result.items.count - 30))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .help(result.category.description)
    }

    // MARK: - 개별 항목 행

    private func junkItemRow(_ item: JunkItem, categoryID: String) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: {
                    viewModel.results
                        .first(where: { $0.id == categoryID })?
                        .items.first(where: { $0.id == item.id })?
                        .isSelected ?? false
                },
                set: { _ in viewModel.toggleItem(in: categoryID, itemID: item.id) }
            ))
            .labelsHidden()
            .controlSize(.small)

            Image(systemName: "doc")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(item.sizeString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
