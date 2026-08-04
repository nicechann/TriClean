//
//  LargeFilesView.swift
//  TriClean
//
//  Large file scan surface separated from Storage summary.
//

import SwiftUI
import AppKit
import StoreKit
import os.log

private struct LargeFilesSecurityScopedAccessToken {
    private let url: URL
    private let started: Bool

    nonisolated init(_ url: URL) {
        self.url = url
        self.started = url.startAccessingSecurityScopedResource()
    }

    nonisolated func stop() {
        guard started else { return }
        url.stopAccessingSecurityScopedResource()
    }
}

struct LargeFilesView: View {
    @EnvironmentObject private var storeManager: StoreManager

    @State private var showPaywall = false

    @State private var minFolderSizeMB: Double = 200
    @State private var selectedFolderURL: URL? = nil
    @State private var isScanning: Bool = false
    @State private var isAutoUpdating: Bool = false
    @State private var isDeleting: Bool = false
    @State private var scanTask: Task<Void, Never>? = nil
    @State private var scanMessage: String = "storage.scan.default_msg".localized
    @State private var folderResults: [FolderInfo] = []
    @State private var ignoredFolderURLs: Set<URL> = []
    @State private var tableSelection = Set<FolderInfo.ID>()

    @State private var deleteTargets: [FolderInfo] = []
    @State private var showingDeleteAlert = false

    @State private var activeScanID = UUID()
    @State private var lastScannedMinSizeMB: Double? = nil
    @State private var topFolderSort: TopFolderSort = .discovered
    @State private var discoveredResults: [FolderInfo] = []

    private var rootResultCount: Int {
        folderResults.filter { $0.depth == 0 }.count
    }

    private var childResultCount: Int {
        folderResults.filter { $0.depth > 0 }.count
    }

    private var selectedFolderDisplayName: String {
        guard let selectedFolderURL else { return "storage.status.folder_none".localized }
        return selectedFolderURL.lastPathComponent.isEmpty ? selectedFolderURL.path : selectedFolderURL.lastPathComponent
    }

    private var minFolderSizeDisplay: String {
        "storage.min_size.display".localized(with: Int(minFolderSizeMB))
    }

    private var scanButtonBusyText: String {
        isAutoUpdating
            ? "storage.scan.updating".localized
            : "storage.scan.scanning".localized
    }

    private enum TopFolderSort: String, CaseIterable, Identifiable {
        case discovered
        case name
        case size

        var id: String { rawValue }

        var title: String {
            switch self {
            case .discovered: return "storage.scan.sort.default".localized
            case .name: return "storage.scan.sort.name".localized
            case .size: return "storage.scan.sort.size".localized
            }
        }
    }

    private enum ScanTrigger {
        case manual
        case auto
    }

    var body: some View {
        let outerPadding: CGFloat = 16
        let sectionInset: CGFloat = 12

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                headerSection
                    .padding(.horizontal, sectionInset)

                if !folderResults.isEmpty {
                    TreemapView(
                        items: folderResults,
                        onItemTapped: { item in openInFinder(item) }
                    )
                    .padding(.horizontal, sectionInset)

                    Divider()
                }

                folderScanSection

                if selectedFolderURL != nil || isScanning || !folderResults.isEmpty {
                    storageStatusSection
                    Divider()
                } else {
                    Divider()
                }

                resultsTableSection
                Spacer(minLength: 10)
            }
            .padding(.horizontal, outerPadding)
            .padding(.top, outerPadding)
            .padding(.bottom, storeManager.isPurchased ? outerPadding : 110)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            if !storeManager.isPurchased {
                Divider()
                UpgradeBottomBanner(onBuyTap: { showPaywall = true })
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
        .task(id: minFolderSizeMB) {
            guard let url = selectedFolderURL else { return }

            try? await Task.sleep(nanoseconds: 250_000_000)

            if lastScannedMinSizeMB == minFolderSizeMB { return }

            await MainActor.run {
                runScan(for: url, minSizeMB: minFolderSizeMB, trigger: .auto)
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("largefiles.title".localized)
                .font(.title2.bold())

            Text("largefiles.subtitle".localized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
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
                    .font(.title3.bold())

                Spacer()

                Button {
                    selectFolderAndScan()
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

                        if isScanning {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(scanButtonBusyText)
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
                .disabled(isScanning || isDeleting)

                if isScanning {
                    Button {
                        cancelActiveScan()
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
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("storage.scan.min_size".localized)
                    .font(.subheadline)
                    .frame(width: 120, alignment: .leading)

                Slider(value: $minFolderSizeMB, in: 10...2000, step: 10)
                    .controlSize(.small)
                    .frame(maxWidth: 260)

                Text("\(Int(minFolderSizeMB)) MB+")
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 90, alignment: .trailing)

                Spacer()
            }

            HStack(spacing: 12) {
                Text("storage.scan.sort".localized)
                    .font(.subheadline)
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $topFolderSort) {
                    ForEach(TopFolderSort.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .font(.subheadline)
                .frame(maxWidth: 270)

                Spacer()
            }
            .onChange(of: topFolderSort) { _ in
                guard !isScanning else { return }
                applyTopFolderSortFromDiscovered()
            }

            if isScanning && topFolderSort != .discovered {
                Text("storage.scan.sort.note".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(scanMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var storageStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("storage.status.header".localized)
                .font(.title3.bold())

            HStack(spacing: 10) {
                infoCard(title: "storage.status.folder".localized, value: selectedFolderDisplayName)
                infoCard(
                    title: "storage.status.visible_results".localized,
                    value: "storage.status.visible_results_value".localized(with: rootResultCount, childResultCount)
                )
                infoCard(title: "storage.status.min_size".localized, value: minFolderSizeDisplay)
            }

            Text(isScanning ? scanButtonBusyText : scanMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultsTableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("storage.results.header".localized)
                    .font(.title3.bold())

                Spacer()

                Button(role: .destructive) {
                    deleteSelectedFolders()
                } label: {
                    Text("common.trash".localized)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(isScanning || isDeleting || tableSelection.isEmpty)
            }

            if folderResults.isEmpty {
                Table(folderResults, selection: $tableSelection) {
                    TableColumn("storage.table.item".localized) { item in
                        itemNameCell(item)
                    }

                    TableColumn("storage.table.size".localized) { item in
                        Text(item.sizeString)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 90, ideal: 110, max: 130)
                }
            } else {
                Table(folderResults, selection: $tableSelection) {
                    TableColumn("storage.table.item".localized) { item in
                        itemNameCell(item)
                    }

                    TableColumn("storage.table.size".localized) { item in
                        Text(item.sizeString)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 90, ideal: 110, max: 130)

                    TableColumn("") { item in
                        Button {
                            openInFinder(item)
                        } label: {
                            Label("common.finder_app".localized, systemImage: "folder")
                        }
                        .labelStyle(.titleAndIcon)
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .help("common.finder".localized)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 90, ideal: 100, max: 110)

                    TableColumn("") { item in
                        Button(role: .destructive) {
                            requestDelete(item)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.red)
                                .padding(6)
                                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(isScanning || isDeleting)
                        .help("common.trash".localized)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 44, ideal: 48, max: 52)
                }
            }
        }
        .frame(minHeight: 320)
        .alert("storage.alert.delete.title".localized, isPresented: $showingDeleteAlert) {
            Button("common.move_to_trash".localized, role: .destructive) { confirmDelete() }
            Button("common.cancel".localized, role: .cancel) { deleteTargets = [] }
        } message: {
            if deleteTargets.count == 1, let target = deleteTargets.first {
                let key = target.isDirectory ? "storage.alert.delete.msg_folder" : "storage.alert.delete.msg_file"
                Text(key.localized(with: target.name))
            } else {
                Text("storage.alert.delete.msg_multi".localized(with: deleteTargets.count))
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(item.depth > 0 ? .subheadline : .body)
                    .foregroundStyle(item.depth > 0 ? .secondary : .primary)
            }
            .padding(.leading, indent)

            Text(pathText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func cancelActiveScan() {
        scanTask?.cancel()
        scanMessage = "storage.msg.canceling".localized
    }

    private func selectFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            selectedFolderURL = url
            tableSelection.removeAll()

            runScan(for: url, minSizeMB: minFolderSizeMB, trigger: .manual)
        }
    }

    private func runScan(for url: URL, minSizeMB: Double, trigger: ScanTrigger) {
        scanTask?.cancel()

        let scanID = UUID()
        activeScanID = scanID

        let root = url.standardizedFileURL
        let ignoredSnapshot = ignoredFolderURLs
        let isAuto = (trigger == .auto)

        isAutoUpdating = isAuto
        isScanning = true
        tableSelection.removeAll()

        switch trigger {
        case .manual:
            scanMessage = "storage.msg.manual".localized(with: url.lastPathComponent)
        case .auto:
            scanMessage = "storage.msg.auto".localized
        }

        if trigger == .manual {
            folderResults = []
            discoveredResults = []
        }

        scanTask = Task(priority: .userInitiated) {
            let token = LargeFilesSecurityScopedAccessToken(root)
            defer { token.stop() }

            var didReplace = (trigger == .manual)

            let stream = Self.scanStructuredItemsBatches(
                of: root,
                minSizeMB: minSizeMB,
                ignoredFolderURLs: ignoredSnapshot,
                batchSize: 220
            )

            for await batch in stream {
                if Task.isCancelled { break }

                let shouldReplace = !didReplace
                await MainActor.run {
                    guard self.activeScanID == scanID else { return }

                    if shouldReplace {
                        self.folderResults = batch
                        self.discoveredResults = batch
                    } else {
                        self.folderResults.append(contentsOf: batch)
                        self.discoveredResults.append(contentsOf: batch)
                    }
                }

                didReplace = true
            }

            await MainActor.run {
                guard self.activeScanID == scanID else { return }

                self.isScanning = false
                self.isAutoUpdating = false
                self.lastScannedMinSizeMB = minSizeMB

                if Task.isCancelled {
                    self.scanMessage = "storage.msg.canceled".localized
                    return
                }

                if !didReplace {
                    self.folderResults = []
                    self.discoveredResults = []
                }

                self.applyTopFolderSortFromDiscovered()

                let results = self.folderResults
                let folderCount = results.filter { $0.isDirectory && $0.depth == 0 }.count
                let fileCount = results.filter { !$0.isDirectory }.count

                if results.isEmpty {
                    self.scanMessage = "storage.msg.no_items".localized(with: root.lastPathComponent)
                } else {
                    self.scanMessage = "storage.msg.completed".localized(with: root.lastPathComponent, folderCount, fileCount)
                }
            }
        }
    }

    @MainActor
    private func applyTopFolderSortFromDiscovered() {
        switch topFolderSort {
        case .discovered:
            folderResults = discoveredResults
        case .name, .size:
            folderResults = Self.sortedTopFolderGroups(in: discoveredResults, by: topFolderSort)
        }
    }

    private static func sortedTopFolderGroups(in results: [FolderInfo], by mode: TopFolderSort) -> [FolderInfo] {
        guard mode != .discovered else { return results }

        var rootItems: [FolderInfo] = []
        rootItems.reserveCapacity(64)

        var topFolders: [FolderInfo] = []
        topFolders.reserveCapacity(64)

        var childrenByParent: [URL: [FolderInfo]] = [:]
        childrenByParent.reserveCapacity(64)

        for item in results {
            if item.depth == 0, item.parentURL == nil, item.isDirectory {
                topFolders.append(item)
            } else if item.depth == 0, item.parentURL == nil, !item.isDirectory {
                rootItems.append(item)
            } else if let parent = item.parentURL {
                childrenByParent[parent.standardizedFileURL, default: []].append(item)
            } else {
                rootItems.append(item)
            }
        }

        switch mode {
        case .name:
            topFolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            topFolders.sort {
                if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .discovered:
            break
        }

        var output: [FolderInfo] = []
        output.reserveCapacity(results.count)

        var included = Set<FolderInfo.ID>()
        included.reserveCapacity(results.count)

        output.append(contentsOf: rootItems)
        for i in rootItems { included.insert(i.id) }

        for folder in topFolders {
            output.append(folder)
            included.insert(folder.id)

            if let children = childrenByParent[folder.url.standardizedFileURL] {
                output.append(contentsOf: children)
                for c in children { included.insert(c.id) }
            }
        }

        if included.count != results.count {
            for item in results where !included.contains(item.id) {
                output.append(item)
            }
        }

        return output
    }

    nonisolated private static func fileSize(from values: URLResourceValues) -> Int {
        values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
    }

    private static func scanStructuredItemsBatches(
        of root: URL,
        minSizeMB: Double,
        ignoredFolderURLs: Set<URL>,
        batchSize: Int
    ) -> AsyncStream<[FolderInfo]> {
        AsyncStream { continuation in
            let producer = Task.detached(priority: .utility) {
                let fm = FileManager.default
                let rootStd = root.standardizedFileURL

                let directKeys: [URLResourceKey] = [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
                    .fileSizeKey
                ]

                guard let directItems = try? fm.contentsOfDirectory(
                    at: rootStd,
                    includingPropertiesForKeys: directKeys,
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.finish()
                    return
                }

                var topFolders: [URL] = []
                var rootFiles: [FolderInfo] = []
                rootFiles.reserveCapacity(64)

                for raw in directItems {
                    if Task.isCancelled { break }

                    let url = raw.standardizedFileURL
                    if ignoredFolderURLs.contains(url) { continue }

                    guard let values = try? url.resourceValues(forKeys: Set(directKeys)) else { continue }

                    if values.isDirectory == true {
                        topFolders.append(url)
                        continue
                    }

                    if values.isRegularFile == true {
                        let size = Int64(Self.fileSize(from: values))
                        let sizeMB = Double(size) / 1024.0 / 1024.0
                        if sizeMB >= minSizeMB {
                            rootFiles.append(FolderInfo(url: url, sizeBytes: size, isDirectory: false, depth: 0, parentURL: nil))
                        }
                    }
                }

                rootFiles.sort { $0.sizeBytes > $1.sizeBytes }

                var idx = 0
                while idx < rootFiles.count {
                    if Task.isCancelled { break }

                    let end = min(idx + max(batchSize, 1), rootFiles.count)
                    continuation.yield(Array(rootFiles[idx..<end]))
                    idx = end
                    await Task.yield()
                }

                let scanKeys: [URLResourceKey] = [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .fileAllocatedSizeKey,
                    .totalFileAllocatedSizeKey,
                    .fileSizeKey,
                    .isPackageKey
                ]

                for folderURL in topFolders {
                    if Task.isCancelled { break }

                    let folder = folderURL.standardizedFileURL
                    if ignoredFolderURLs.contains(folder) { continue }

                    guard let enumerator = fm.enumerator(
                        at: folder,
                        includingPropertiesForKeys: scanKeys,
                        options: [.skipsHiddenFiles],
                        errorHandler: { _, _ in true }
                    ) else {
                        continue
                    }

                    var total: Int64 = 0
                    var children: [FolderInfo] = []
                    children.reserveCapacity(64)

                    var packagePrefixes: [String] = []
                    packagePrefixes.reserveCapacity(8)

                    let minBytes = Int64(minSizeMB * 1024.0 * 1024.0)

                    while let rawURL = enumerator.nextObject() as? URL {
                        if Task.isCancelled { break }

                        let url = rawURL.standardizedFileURL

                        if ignoredFolderURLs.contains(url) {
                            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                                enumerator.skipDescendants()
                            }
                            continue
                        }

                        guard let values = try? url.resourceValues(forKeys: Set(scanKeys)) else { continue }

                        if values.isDirectory == true && values.isPackage == true {
                            let prefix = url.path.hasSuffix("/") ? url.path : (url.path + "/")
                            packagePrefixes.append(prefix)
                            continue
                        }

                        guard values.isRegularFile == true else { continue }

                        let size = Int64(Self.fileSize(from: values))
                        total += size

                        guard size >= minBytes else { continue }

                        let path = url.path
                        var isInsidePackage = false
                        for prefix in packagePrefixes {
                            if path.hasPrefix(prefix) {
                                isInsidePackage = true
                                break
                            }
                        }
                        if isInsidePackage { continue }

                        children.append(FolderInfo(url: url, sizeBytes: size, isDirectory: false, depth: 1, parentURL: folder))
                    }

                    if Task.isCancelled { break }
                    guard total >= minBytes else { continue }

                    continuation.yield([
                        FolderInfo(url: folder, sizeBytes: total, isDirectory: true, depth: 0, parentURL: nil)
                    ])
                    await Task.yield()

                    if !children.isEmpty {
                        children.sort { $0.sizeBytes > $1.sizeBytes }

                        var j = 0
                        while j < children.count {
                            if Task.isCancelled { break }

                            let end = min(j + max(batchSize, 1), children.count)
                            continuation.yield(Array(children[j..<end]))
                            j = end
                            await Task.yield()
                        }
                    }
                }

                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    private func openInFinder(_ item: FolderInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func requestDelete(_ item: FolderInfo) {
        guard storeManager.isPurchased else {
            showPaywall = true
            return
        }
        deleteTargets = [item]
        showingDeleteAlert = true
    }

    private func deleteSelectedFolders() {
        guard storeManager.isPurchased else {
            showPaywall = true
            return
        }
        let selected = folderResults.filter { tableSelection.contains($0.id) }
        guard !selected.isEmpty else { return }
        deleteTargets = selected
        showingDeleteAlert = true
    }

    private struct LargeDeleteOutcome: Sendable {
        let succeededURLs: Set<URL>
        let rejectedCount: Int
    }

    private func confirmDelete() {
        guard storeManager.isPurchased else {
            deleteTargets = []
            showPaywall = true
            return
        }
        let candidates = Self.normalizedDeleteTargets(deleteTargets)
        guard !candidates.isEmpty else { return }
        guard !isDeleting else { return }
        guard let rootURL = selectedFolderURL?.standardizedFileURL else {
            deleteTargets = []
            scanMessage = "storage.msg.trash_failed".localized
            return
        }

        isDeleting = true
        scanMessage = "storage.msg.trash_moving".localized(with: candidates.count)

        Task {
            let outcome = await Task.detached(priority: .utility) {
                await Self.moveToTrash(candidates, selectedRootURL: rootURL)
            }.value
            let succeededURLs = outcome.succeededURLs
            let acceptedCount = max(0, candidates.count - outcome.rejectedCount)
            let failedCount = outcome.rejectedCount + max(0, acceptedCount - succeededURLs.count)

            guard !succeededURLs.isEmpty else {
                isDeleting = false
                deleteTargets = []
                scanMessage = "storage.msg.trash_failed".localized
                return
            }

            ignoredFolderURLs.formUnion(succeededURLs)

            folderResults.removeAll { info in
                let u = info.url.standardizedFileURL
                if succeededURLs.contains(u) { return true }
                if let p = info.parentURL?.standardizedFileURL, succeededURLs.contains(p) { return true }
                return false
            }

            discoveredResults.removeAll { info in
                let u = info.url.standardizedFileURL
                if succeededURLs.contains(u) { return true }
                if let p = info.parentURL?.standardizedFileURL, succeededURLs.contains(p) { return true }
                return false
            }

            let remainingIDs = Set(folderResults.map(\.id))
            tableSelection.formIntersection(remainingIDs)

            isDeleting = false
            deleteTargets = []
            scanMessage = failedCount > 0
                ? "storage.msg.trash_partial".localized(with: succeededURLs.count, failedCount)
                : "storage.msg.trash_done".localized(with: succeededURLs.count)
        }
    }

    nonisolated private static func normalizedDeleteTargets(_ items: [FolderInfo]) -> [FolderInfo] {
        let sorted = items.sorted { lhs, rhs in
            let lhsPath = DeletionSafety.resolvedPath(for: lhs.url)
            let rhsPath = DeletionSafety.resolvedPath(for: rhs.url)
            if lhsPath.count == rhsPath.count { return lhsPath < rhsPath }
            return lhsPath.count < rhsPath.count
        }

        var result: [FolderInfo] = []
        for item in sorted {
            let isCoveredByParent = result.contains { parent in
                parent.isDirectory && DeletionSafety.isContained(item.url, inScope: parent.url)
            }
            if !isCoveredByParent {
                result.append(item)
            }
        }
        return result
    }

    nonisolated private static func moveToTrash(
        _ candidates: [FolderInfo],
        selectedRootURL: URL
    ) async -> LargeDeleteOutcome {
        let token = LargeFilesSecurityScopedAccessToken(selectedRootURL)
        defer { token.stop() }

        // 사용자가 선택한 스캔 루트의 하위 항목만 삭제할 수 있습니다.
        // 루트 자체, 형제 경로, 심볼릭 링크로 빠져나간 경로는 모두 제외합니다.
        let sanitized = DeletionSafety.sanitize(candidates, scope: selectedRootURL, url: \.url)
        let identityValidated = DeletionSafety.revalidateIdentity(
            sanitized.accepted,
            url: \.url,
            identity: \.fileIdentity
        )
        var succeededURLs = Set<URL>()
        let fm = FileManager.default
        var runtimeRejectedCount = 0

        for item in identityValidated.accepted {
            let target = item.url.standardizedFileURL

            // 여러 항목을 순차 처리하는 동안 같은 경로의 파일이나 폴더가 교체될 수 있으므로
            // 실제 휴지통 이동 직전에 스캔 당시 항목과 동일한지 다시 확인합니다.
            guard DeletionSafety.isIdentityCurrent(
                item,
                url: \.url,
                identity: \.fileIdentity
            ) else {
                runtimeRejectedCount += 1
                continue
            }

            do {
                try fm.trashItem(at: target, resultingItemURL: nil)
                succeededURLs.insert(target)
            } catch {
                // trashItem 실패 후 NSWorkspace 폴백 직전에도 교체 여부를 재검증합니다.
                guard DeletionSafety.isIdentityCurrent(
                    item,
                    url: \.url,
                    identity: \.fileIdentity
                ) else {
                    runtimeRejectedCount += 1
                    continue
                }
                let recycled = await recycleWithWorkspace(target)
                if recycled {
                    succeededURLs.insert(target)
                } else {
                    Logger(subsystem: "com.nicechann.TriClean", category: "LargeFiles")
                        .error("Trash failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        return LargeDeleteOutcome(
            succeededURLs: succeededURLs,
            rejectedCount: sanitized.rejectedCount
                + identityValidated.rejectedCount
                + runtimeRejectedCount
        )
    }

    @MainActor
    private static func recycleWithWorkspace(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

}
