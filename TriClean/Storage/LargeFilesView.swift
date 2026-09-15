//
//  LargeFilesView.swift
//  TriClean
//
//  Large file scan surface separated from Storage summary.
//
//  스캔·정렬·삭제 로직은 `LargeFilesViewModel`에 있다. 이 파일은 표시만 담당한다.
//

import SwiftUI
import AppKit
import StoreKit

struct LargeFilesView: View {
    @EnvironmentObject private var storeManager: StoreManager
    @EnvironmentObject private var viewModel: LargeFilesViewModel

    @State private var showPaywall = false
    @State private var previewTarget: QuickLookTarget? = nil

    // Free users can verify scan quality with a small preview; Lifetime Access reveals the full result list.
    private let freePreviewItemLimit = 5

    private var displayedFolderResults: [FolderInfo] {
        storeManager.isPurchased
            ? viewModel.folderResults
            : Array(viewModel.folderResults.prefix(freePreviewItemLimit))
    }

    var body: some View {
        let outerPadding: CGFloat = 16
        let sectionInset: CGFloat = 12

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                headerSection
                    .padding(.horizontal, sectionInset)

                if viewModel.hasResults {
                    TreemapView(
                        // Keep the visualization truthful: it represents the full scan result.
                        // Free users only get a limited list preview below.
                        items: viewModel.folderResults,
                        onItemTapped: { item in
                            if storeManager.isPurchased {
                                viewModel.openInFinder(item)
                            } else {
                                showPaywall = true
                            }
                        }
                    )
                    .padding(.horizontal, sectionInset)

                    Divider()
                }

                folderScanSection

                if viewModel.selectedFolderURL != nil || viewModel.isScanning || viewModel.hasResults {
                    storageStatusSection
                }

                Divider()

                resultsTableSection
                Spacer(minLength: 10)
            }
            .padding(.horizontal, outerPadding)
            .padding(.top, outerPadding)
            .padding(.bottom, storeManager.isPurchased ? outerPadding : 110)
        }
        // ✅ macOS 26: 스크롤 콘텐츠가 타이틀바와 겹치지 않도록 상단 가장자리 불투명 처리
        .hardTopScrollEdge()
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            if !storeManager.isPurchased {
                Divider()
                UpgradeBottomBanner(
                    description: largeFilesFreePreviewDescription,
                    onBuyTap: { showPaywall = true }
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal, outerPadding + sectionInset)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(storeManager)
        }
        .sheet(item: $previewTarget) { target in
            QuickLookPreviewSheet(target: target) { previewTarget = nil }
        }
        // 최소 크기 슬라이더 디바운스.
        // ⚠️ `try?`로 취소를 삼키면 안 된다. 슬라이더를 끄는 동안 취소된 태스크까지
        //    전부 스캔을 시작해 파일시스템 순회가 폭주한다.
        .task(id: viewModel.minFolderSizeMB) {
            let target = viewModel.minFolderSizeMB
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return   // 취소됨 — 더 최신 값이 들어왔다는 뜻이므로 스캔하지 않는다.
            }
            guard !Task.isCancelled else { return }
            viewModel.autoRescanIfNeeded(minSizeMB: target)
        }
        // 진입 시점의 최소 크기를 기준값으로 고정한다(진입만으로 스캔이 시작되지 않도록).
        .onAppear {
            viewModel.onAppear()
        }
        // 탭을 벗어나면 뷰가 파괴되므로 진행 중인 스캔을 반드시 멈춘다.
        .onDisappear {
            viewModel.onDisappear()
        }
    }

    private var largeFilesFreePreviewDescription: String? {
        guard viewModel.folderResults.count > displayedFolderResults.count else { return nil }
        return "upgrade.bottom.preview.items".localized(
            with: viewModel.folderResults.count.formatted(),
            displayedFolderResults.count.formatted()
        )
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("largefiles.title".localized)
                .appFont(.title2, weight: .bold)

            Text("largefiles.subtitle".localized)
                .appFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .appFont(.headline)
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
    }

    private var folderScanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("storage.scan.header".localized)
                    .appFont(.title3, weight: .bold)

                Spacer()

                Button {
                    viewModel.selectFolderAndScan()
                } label: {
                    ZStack {
                        Group {
                            Text("storage.scan.btn".localized)
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("storage.scan.updating".localized)
                            }
                        }
                        .opacity(0)

                        if viewModel.isScanning {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(viewModel.scanButtonBusyText)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("storage.scan.btn".localized)
                                .lineLimit(1)
                        }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!viewModel.canScan)
                .accessibilityLabel(Text("storage.scan.btn".localized))

                if viewModel.isScanning {
                    Button {
                        viewModel.cancelActiveScan()
                    } label: {
                        Text("common.cancel".localized)
                            .lineLimit(1)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                }
            }

            Text("storage.scan.tip".localized)
                .appFont(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("storage.scan.min_size".localized)
                    .appFont(.subheadline)
                    .frame(width: 120, alignment: .leading)

                Slider(value: $viewModel.minFolderSizeMB, in: 10...2000, step: 10)
                    .controlSize(.small)
                    .frame(maxWidth: 260)
                    .accessibilityLabel(Text("storage.scan.min_size".localized))
                    .accessibilityValue(Text(viewModel.minFolderSizeDisplay))

                // ✅ 이미 존재하는 storage.min_size.display 키로 통일
                Text(viewModel.minFolderSizeDisplay)
                    .appFont(.subheadline, monospacedDigit: true)
                    .frame(width: 90, alignment: .trailing)

                Spacer()
            }

            HStack(spacing: 12) {
                Text("storage.scan.sort".localized)
                    .appFont(.subheadline)
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $viewModel.topFolderSort) {
                    ForEach(LargeFilesViewModel.TopFolderSort.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .appFont(.subheadline)
                .frame(maxWidth: 270)
                .accessibilityLabel(Text("storage.scan.sort".localized))

                Spacer()
            }
            .onChange(of: viewModel.topFolderSort) { _ in
                guard !viewModel.isScanning else { return }
                viewModel.applyTopFolderSortFromDiscovered()
            }

            if viewModel.isScanning && viewModel.topFolderSort != .discovered {
                Text("storage.scan.sort.note".localized)
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(viewModel.scanMessage)
                .appFont(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var storageStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("storage.status.header".localized)
                .appFont(.title3, weight: .bold)

            HStack(spacing: 10) {
                infoCard(
                    title: "storage.status.folder".localized,
                    value: viewModel.selectedFolderDisplayName
                )
                infoCard(
                    title: "storage.status.visible_results".localized,
                    value: "storage.status.visible_results_value".localized(
                        with: viewModel.rootResultCount, viewModel.childResultCount
                    )
                )
                infoCard(
                    title: "storage.status.min_size".localized,
                    value: viewModel.minFolderSizeDisplay
                )
            }

            Text(viewModel.isScanning ? viewModel.scanButtonBusyText : viewModel.scanMessage)
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultsTableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("storage.results.header".localized)
                    .appFont(.title3, weight: .bold)

                if !storeManager.isPurchased,
                   viewModel.folderResults.count > displayedFolderResults.count {
                    Label {
                        Text(
                            "upgrade.preview.count".localized(
                                with: viewModel.folderResults.count,
                                displayedFolderResults.count
                            )
                        )
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    .appFont(.callout, weight: .semibold)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }

                Spacer()

                Button(role: .destructive) {
                    requestDeleteSelected()
                } label: {
                    Text("common.trash".localized)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(viewModel.isScanning || viewModel.isDeleting || viewModel.tableSelection.isEmpty)
            }

            // 결과 유무로 Table 구조를 바꾸면 첫 배치가 도착하는 순간 NSTableView가
            // 통째로 재생성되어 선택과 스크롤 위치가 리셋된다. 하나의 Table만 쓴다.
            Table(displayedFolderResults, selection: $viewModel.tableSelection) {
                TableColumn("storage.table.item".localized) { item in
                    itemNameCell(item)
                }

                TableColumn("storage.table.size".localized) { item in
                    Text(item.sizeString)
                        .appFont(.body, monospacedDigit: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 90, ideal: 110, max: 130)

                // 삭제 판단 직전에 내용을 확인할 수 있게 한다.
                // 폴더는 QuickLook으로 볼 것이 없으므로 파일에만 노출한다.
                TableColumn("") { item in
                    if item.isDirectory {
                        Color.clear.frame(width: 0, height: 0)
                    } else {
                        Button {
                            previewTarget = QuickLookTarget(url: item.url, sizeText: item.sizeString)
                        } label: {
                            Image(systemName: "eye")
                                .appIconFont(13, weight: .semibold)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                        .help("common.preview".localized)
                        .accessibilityLabel(Text("common.preview".localized + " — " + item.name))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .width(min: 40, ideal: 44, max: 48)

                TableColumn("") { item in
                    Button {
                        viewModel.openInFinder(item)
                    } label: {
                        Label("common.finder_app".localized, systemImage: "folder")
                    }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("common.finder".localized)
                    .accessibilityLabel(Text("common.finder".localized + " — " + item.name))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 90, ideal: 100, max: 110)

                TableColumn("") { item in
                    Button(role: .destructive) {
                        requestDelete(item)
                    } label: {
                        Image(systemName: "trash")
                            .appIconFont(13, weight: .semibold)
                            .foregroundStyle(.red)
                            .padding(6)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isScanning || viewModel.isDeleting)
                    .help("common.trash".localized)
                    .accessibilityLabel(Text("common.trash".localized + " — " + item.name))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 44, ideal: 48, max: 52)
            }
        }
        .frame(minHeight: 320)
        .alert("storage.alert.delete.title".localized, isPresented: $viewModel.showingDeleteAlert) {
            Button("common.move_to_trash".localized, role: .destructive) {
                viewModel.confirmDelete()
            }
            Button("common.cancel".localized, role: .cancel) {
                viewModel.cancelDeleteRequest()
            }
        } message: {
            if viewModel.deleteTargets.count == 1, let target = viewModel.deleteTargets.first {
                let key = target.isDirectory ? "storage.alert.delete.msg_folder" : "storage.alert.delete.msg_file"
                Text(key.localized(with: target.name))
            } else {
                Text("storage.alert.delete.msg_multi".localized(with: viewModel.deleteTargets.count))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 결제 게이팅

    private func requestDelete(_ item: FolderInfo) {
        guard storeManager.isPurchased else {
            showPaywall = true
            return
        }
        viewModel.requestDelete(item)
    }

    private func requestDeleteSelected() {
        guard storeManager.isPurchased else {
            showPaywall = true
            return
        }
        viewModel.requestDeleteSelected()
    }

    private func itemNameCell(_ item: FolderInfo) -> some View {
        let indent = CGFloat(item.depth) * 18
        let pathText: String = {
            if let parent = item.parentURL {
                let prefix = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
                if item.path.hasPrefix(prefix) {
                    return String(item.path.dropFirst(prefix.count))
                }
            }
            return item.path
        }()

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if item.depth > 0 {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                Text(item.name)
                    .appFont(item.depth > 0 ? .subheadline : .body)
                    .foregroundStyle(item.depth > 0 ? .secondary : .primary)
            }
            .padding(.leading, indent)

            Text(pathText)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
