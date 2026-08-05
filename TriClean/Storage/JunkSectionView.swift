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
    @State private var cleanRequest: CleanRequest?
    @State private var expandedCategories: Set<String> = []
    @State private var showAllItems: Set<String> = []

    private struct CleanRequest: Identifiable {
        let categoryID: String?
        let categoryName: String?
        let selectedCount: Int
        let selectedBytesString: String

        var id: String { categoryID ?? "__all_categories__" }
    }

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
                        requestGlobalClean()
                    } label: {
                        Label("junk.section.clean_all".localized, systemImage: "trash")
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
        .alert(item: $cleanRequest) { request in
            Alert(
                title: Text(cleanAlertTitle(for: request)),
                message: Text(cleanAlertMessage(for: request)),
                primaryButton: .destructive(Text("common.move_to_trash".localized)) {
                    guard storeManager.isPurchased else {
                        onUpgradeRequired()
                        return
                    }

                    if let categoryID = request.categoryID {
                        viewModel.cleanSelected(in: categoryID)
                    } else {
                        viewModel.cleanSelected()
                    }
                },
                secondaryButton: .cancel(Text("common.cancel".localized))
            )
        }
    }

    // MARK: - 카테고리 행 (펼침/접힘)

    private func junkCategoryRow(_ result: JunkScanResult) -> some View {
        let isExpanded = expandedCategories.contains(result.id)
        let isShowingAll = showAllItems.contains(result.id)
        let visibleItems = result.displayedItems(showAll: isShowingAll)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    viewModel.toggleAll(in: result.id)
                } label: {
                    Image(systemName: selectionIcon(for: result.selectionState))
                        .foregroundStyle(selectionColor(for: result.selectionState))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(
                    result.selectionState == .all
                        ? "junk.item.deselect_all".localized
                        : "junk.item.select_all".localized
                )
                .accessibilityLabel(
                    Text(
                        result.selectionState == .all
                            ? "junk.item.deselect_all".localized
                            : "junk.item.select_all".localized
                    )
                )
                .accessibilityValue(Text("\(result.selectedCount)/\(result.items.count)"))
                .disabled(viewModel.isScanning || viewModel.isCleaning)

                Button {
                    toggleExpanded(result.id)
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
                                Text("\(result.selectedCount)/\(result.items.count)")
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    requestCategoryClean(result)
                } label: {
                    Label("junk.section.clean".localized, systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(result.selectedCount == 0 || viewModel.isScanning || viewModel.isCleaning)
            }
            .padding(10)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 10)

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

                LazyVStack(spacing: 0) {
                    ForEach(visibleItems) { item in
                        junkItemRow(item, categoryID: result.id)
                    }

                    if result.items.count > 30 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isShowingAll {
                                    showAllItems.remove(result.id)
                                } else {
                                    showAllItems.insert(result.id)
                                }
                            }
                        } label: {
                            Text(
                                isShowingAll
                                    ? "junk.item.show_less".localized
                                    : "junk.item.show_more".localized(with: result.items.count - 30)
                            )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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

    private func toggleExpanded(_ categoryID: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedCategories.contains(categoryID) {
                expandedCategories.remove(categoryID)
            } else {
                expandedCategories.insert(categoryID)
            }
        }
    }

    private func requestGlobalClean() {
        guard storeManager.isPurchased else {
            onUpgradeRequired()
            return
        }

        cleanRequest = CleanRequest(
            categoryID: nil,
            categoryName: nil,
            selectedCount: JunkScannerViewModel.selectedItems(in: viewModel.results).count,
            selectedBytesString: viewModel.selectedJunkString
        )
    }

    private func requestCategoryClean(_ result: JunkScanResult) {
        guard storeManager.isPurchased else {
            onUpgradeRequired()
            return
        }
        guard result.selectedCount > 0 else { return }

        cleanRequest = CleanRequest(
            categoryID: result.id,
            categoryName: result.category.name,
            selectedCount: result.selectedCount,
            selectedBytesString: result.selectedString
        )
    }

    private func cleanAlertTitle(for request: CleanRequest) -> String {
        guard let categoryName = request.categoryName else {
            return "junk.section.alert.title".localized
        }
        return "junk.category.alert.title".localized(with: categoryName)
    }

    private func cleanAlertMessage(for request: CleanRequest) -> String {
        guard request.categoryID != nil else {
            return "junk.section.alert.message".localized(with: request.selectedBytesString)
        }
        return "junk.category.alert.message".localized(
            with: request.selectedCount,
            request.selectedBytesString
        )
    }

    private func selectionIcon(for state: JunkSelectionState) -> String {
        switch state {
        case .none: return "square"
        case .partial: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }

    private func selectionColor(for state: JunkSelectionState) -> Color {
        state == .none ? .secondary : .accentColor
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
