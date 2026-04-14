//
//  DuplicateFinderView.swift
//  TriClean
//
//  중복 파일 탐색 & 삭제 화면
//  ContentView의 사이드바에 "Duplicates" 항목으로 추가
//

import SwiftUI

struct DuplicateFinderView: View {
    @StateObject private var viewModel = DuplicateScannerViewModel()
    @State private var showDeleteConfirm = false
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

            Spacer()
        }
        .padding()
        .alert("duplicates.alert.title".localized, isPresented: $showDeleteConfirm) {
            Button("common.move_to_trash".localized, role: .destructive) {
                viewModel.deleteDuplicates()
            }
            Button("common.cancel".localized, role: .cancel) {}
        } message: {
            Text("duplicates.alert.message".localized)
        }
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("duplicates.title".localized)
                    .font(.title2.bold())
                Text("duplicates.subtitle".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.scanFolderURL != nil {
                HStack(spacing: 4) {
                    Text("duplicates.min_size".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $viewModel.minFileSizeKB) {
                        Text("10 KB").tag(10)
                        Text("100 KB").tag(100)
                        Text("1 MB").tag(1024)
                        Text("10 MB").tag(10240)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .controlSize(.small)
                }

                Button {
                    viewModel.selectFolder()
                } label: {
                    Label("duplicates.change_folder".localized, systemImage: "folder")
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
    }

    private var folderSelectionSection: some View {
        GroupBox {
            VStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text("duplicates.select_folder_title".localized)
                    .font(.headline)

                Text("duplicates.select_folder_desc".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("duplicates.select_folder".localized) {
                    viewModel.selectFolder()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private var scanningSection: some View {
        VStack(spacing: 16) {
            ProgressView(value: viewModel.progress) {
                Text(viewModel.phase.localizedTitle)
                    .font(.subheadline.bold())
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 400)

            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                summaryCard(
                    title: "duplicates.summary.groups".localized,
                    value: "duplicates.count_format".localized(with: viewModel.totalDuplicateGroups),
                    icon: "doc.on.doc.fill",
                    color: .orange
                )
                summaryCard(
                    title: "duplicates.summary.reclaimable".localized,
                    value: viewModel.totalReclaimableString,
                    icon: "externaldrive.badge.checkmark",
                    color: .green
                )
                summaryCard(
                    title: "duplicates.summary.scanned".localized,
                    value: "duplicates.count_format".localized(with: viewModel.totalFilesScanned),
                    icon: "doc.text.magnifyingglass",
                    color: .blue
                )
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.groups) { group in
                        duplicateGroupRow(group)
                    }
                }
            }

            HStack {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("duplicates.clean_selected".localized(with: viewModel.totalReclaimableString), systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(viewModel.groups.isEmpty)
            }
        }
    }

    private var emptySection: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(viewModel.phase == .done ? "duplicates.empty.done_title".localized : "duplicates.empty.idle_title".localized)
                .font(.headline)
            Text(viewModel.phase == .done
                 ? "duplicates.empty.done_desc".localized
                 : "duplicates.empty.idle_desc".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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
                            Text("duplicates.group.files".localized(with: group.files.count))
                                .font(.subheadline.bold())
                            Text("duplicates.group.detail".localized(with: group.fileSizeString, group.reclaimableString))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()

                    ForEach(group.files) { file in
                        HStack(spacing: 8) {
                            Button {
                                viewModel.toggleKeep(groupID: group.id, fileID: file.id)
                            } label: {
                                Image(systemName: file.isKeep ? "checkmark.shield.fill" : "xmark.circle")
                                    .foregroundStyle(file.isKeep ? .green : .red)
                            }
                            .buttonStyle(.plain)
                            .help(file.isKeep ? "duplicates.file.help.keep".localized : "duplicates.file.help.delete".localized)

                            Image(systemName: "doc")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name)
                                    .font(.caption)
                                    .foregroundStyle(file.isKeep ? .primary : .secondary)
                                    .strikethrough(!file.isKeep)
                                Text(file.parentFolder)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            if let date = file.modificationDate {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Text(file.isKeep ? "duplicates.file.keep".localized : "duplicates.file.delete".localized)
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
}

#Preview {
    DuplicateFinderView()
        .frame(width: 800, height: 600)
}
