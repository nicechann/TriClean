//
//  DuplicateFinderView.swift
//  TriClean
//
//  중복 파일 탐색 & 삭제 화면
//  ContentView의 사이드바에 "Duplicates" 항목으로 추가
//

import SwiftUI

struct DuplicateFinderView: View {
    // ✅ [공유 모델] 앱 레벨에서 주입된 동일 인스턴스를 사용
    @EnvironmentObject private var viewModel: DuplicateScannerViewModel
    @EnvironmentObject private var storeManager: StoreManager
    @State private var showDeleteConfirm = false
    @State private var showPaywall = false
    @State private var expandedGroupIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            if viewModel.scanFolderURL == nil {
                folderSelectionSection
            } else if viewModel.isScanning {
                scanningSection
            } else if !viewModel.groups.isEmpty {
                resultsSection
            } else {
                emptySection
            }

            Spacer(minLength: 0)
        }
        .padding()
        .alert("duplicate.delete_confirm.title".localized, isPresented: $showDeleteConfirm) {
            Button("common.move_to_trash".localized, role: .destructive) {
                guard storeManager.isPurchased else {
                    showPaywall = true
                    return
                }
                viewModel.deleteDuplicates()
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text(
                "duplicate.delete_confirm.message".localized(
                    with: viewModel.selectedDeleteCount,
                    viewModel.selectedReclaimableString
                )
            )
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
        .alert(item: $viewModel.lastCleanupResult) { result in
            Alert(
                title: Text("duplicate.cleanup_result.title".localized),
                message: Text(cleanupMessage(for: result)),
                dismissButton: .default(Text("common.close".localized))
            )
        }
    }

    // MARK: - 헤더

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("duplicate.header.title".localized)
                        .font(.title2.bold())
                    Text("duplicate.header.subtitle".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.scanFolderURL != nil {
                    HStack(spacing: 4) {
                        Text("duplicate.header.min_size".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $viewModel.minFileSizeKB) {
                            // ✅ 단위 표기를 로컬라이즈 키로 분리 (러시아어는 КБ/МБ)
                            Text("common.unit.kb".localized(with: 10)).tag(10)
                            Text("common.unit.kb".localized(with: 100)).tag(100)
                            Text("common.unit.mb".localized(with: 1)).tag(1024)
                            Text("common.unit.mb".localized(with: 10)).tag(10240)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                        .controlSize(.small)
                    }

                    Button {
                        viewModel.selectFolder()
                    } label: {
                        Label("duplicate.header.change_folder".localized, systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        viewModel.scan()
                    } label: {
                        Label("common.scan".localized, systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isScanning)
                }
            }

            if viewModel.scanFolderURL != nil {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(viewModel.selectedFolderPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    // MARK: - 폴더 선택

    private var folderSelectionSection: some View {
        GroupBox {
            VStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text("duplicate.empty.select_title".localized)
                    .font(.headline)

                Text("duplicate.empty.select_body".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("duplicate.header.select_folder".localized) {
                    viewModel.selectFolder()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    // MARK: - 스캔 중

    private var scanningSection: some View {
        VStack(spacing: 16) {
            ProgressView(value: viewModel.progress) {
                Text(viewModel.phase.displayText)
                    .font(.subheadline.bold())
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 420)

            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - 결과

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                summaryCard(
                    title: "duplicate.summary.groups".localized,
                    value: "\(viewModel.totalDuplicateGroups)",
                    icon: "doc.on.doc.fill",
                    color: .orange
                )
                summaryCard(
                    title: "duplicate.summary.selected_files".localized,
                    value: "\(viewModel.selectedDeleteCount)",
                    icon: "checklist.checked",
                    color: .blue
                )
                summaryCard(
                    title: "duplicate.summary.selected_space".localized,
                    value: viewModel.selectedReclaimableString,
                    icon: "externaldrive.badge.checkmark",
                    color: .green
                )
                summaryCard(
                    title: "duplicate.summary.scanned_files".localized,
                    value: "\(viewModel.totalFilesScanned)",
                    icon: "doc.text.magnifyingglass",
                    color: .purple
                )
            }

            selectionGuideCard

            HStack(spacing: 8) {
                Button {
                    viewModel.applyRecommendedSelection()
                } label: {
                    Label("duplicate.action.apply_recommended".localized, systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("duplicate.action.apply_recommended.help".localized)

                Button {
                    viewModel.clearDeleteSelection()
                } label: {
                    Label("duplicate.action.clear_selection".localized, systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!viewModel.canDeleteSelected)
                .help("duplicate.action.clear_selection.help".localized)

                Spacer()

                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.groups) { group in
                        duplicateGroupRow(group)
                    }
                }
            }

            HStack {
                Text(
                    "duplicate.footer.summary".localized(
                        with: viewModel.groupsWithSelectedDeletes,
                        viewModel.selectedDeleteCount,
                        viewModel.selectedReclaimableString
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive) {
                    if storeManager.isPurchased {
                        showDeleteConfirm = true
                    } else {
                        showPaywall = true
                    }
                } label: {
                    Label(
                        "duplicate.footer.delete".localized(with: viewModel.selectedDeleteCount, viewModel.selectedReclaimableString),
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!viewModel.canDeleteSelected)
            }
        }
    }

    // MARK: - 빈 상태

    private var emptySection: some View {
        VStack(spacing: 12) {
            Image(systemName: emptyIconName)
                .font(.largeTitle)
                .foregroundStyle(emptyIconColor)
            Text(emptyTitle)
                .font(.headline)
            Text(emptyBody)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyIconName: String {
        switch viewModel.phase {
        case .accessDenied: return "exclamationmark.triangle"
        case .done:         return "checkmark.seal"
        default:            return "doc.text.magnifyingglass"
        }
    }

    private var emptyIconColor: Color {
        switch viewModel.phase {
        case .accessDenied: return .orange
        case .done:         return .green
        default:            return .secondary
        }
    }

    private var emptyTitle: String {
        switch viewModel.phase {
        case .accessDenied: return "duplicate.empty.access_title".localized
        case .done:         return "duplicate.empty.none_title".localized
        default:            return "duplicate.empty.waiting_title".localized
        }
    }

    private var emptyBody: String {
        switch viewModel.phase {
        case .accessDenied: return "duplicate.empty.access_body".localized
        case .done:         return "duplicate.empty.none_body".localized
        default:            return "duplicate.empty.waiting_body".localized
        }
    }

    // MARK: - 서브뷰

    private var selectionGuideCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("duplicate.selection.card_title".localized)
                .font(.subheadline.bold())
            Text("duplicate.selection.card_body".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func summaryCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(value)
                .font(.title3.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func duplicateGroupRow(_ group: DuplicateGroup) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)

        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedGroupIDs.remove(group.id)
                        } else {
                            expandedGroupIDs.insert(group.id)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("duplicate.group.header".localized(with: group.files.count, group.fileSizeString))
                                .font(.subheadline.bold())
                            Text("duplicate.group.subheader".localized(with: group.selectedDeleteCount, group.selectedDeleteBytesString))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()

                    HStack(spacing: 8) {
                        Button("duplicate.group.keep_oldest".localized) {
                            viewModel.keepOldest(in: group.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("duplicate.group.keep_newest".localized) {
                            viewModel.keepNewest(in: group.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        Text("duplicate.group.keep_hint".localized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(group.files) { file in
                        HStack(spacing: 8) {
                            Button {
                                viewModel.toggleKeep(groupID: group.id, fileID: file.id)
                            } label: {
                                Image(systemName: file.isKeep ? "checkmark.shield.fill" : "xmark.circle")
                                    .foregroundStyle(file.isKeep ? .green : .red)
                            }
                            .buttonStyle(.plain)
                            .help(
                                file.isKeep
                                    ? "duplicate.file.help.keep".localized
                                    : "duplicate.file.help.delete".localized
                            )

                            Image(systemName: "doc")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name)
                                    .font(.caption)
                                    .foregroundStyle(file.isKeep ? .primary : .secondary)
                                    .strikethrough(!file.isKeep)
                                    .lineLimit(1)
                                Text(file.path)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            if let date = file.modificationDate {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Button {
                                viewModel.revealInFinder(file.url)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.plain)
                            .help("duplicate.file.reveal".localized)

                            Text(file.isKeep ? "duplicate.file.keep".localized : "duplicate.file.delete".localized)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        file.isKeep
                                            ? Color.green.opacity(0.15)
                                            : Color.red.opacity(0.15)
                                    )
                                )
                                .foregroundStyle(file.isKeep ? .green : .red)
                        }
                    }
                }
            }
        }
    }

    private func cleanupMessage(for result: DuplicateCleanupResult) -> String {
        if result.failedCount > 0 {
            return "duplicate.cleanup_result.body_with_failures".localized(
                with: result.deletedCount,
                result.deletedBytesString,
                result.failedCount
            )
        }
        return "duplicate.cleanup_result.body".localized(with: result.deletedCount, result.deletedBytesString)
    }
}

#Preview {
    DuplicateFinderView()
        .environmentObject(DuplicateScannerViewModel())
        .environmentObject(StoreManager.shared)
        .frame(width: 960, height: 720)
}
