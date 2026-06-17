//
//  PhotosView.swift
//  TriClean
//
//  사진 관리자 화면 (1단계 스캐폴딩).
//  폴더 선택 → 이미지 수집 → 썸네일 그리드 표시.
//  유사/흐릿/스크린샷 분류 및 삭제 UI는 이후 단계에서 추가됩니다.
//

import SwiftUI
import AppKit
import ImageIO

// MARK: - 썸네일 캐시 (뷰 레이어 전용)

/// macOS 13 배포 타깃에서 NSImage(아직 Sendable 아님)를 actor 경계 너머로
/// 안전하게 전달하기 위한 래퍼. 생성 직후 단일 소유로만 다루므로 안전합니다.
private struct ThumbnailBox: @unchecked Sendable {
    let value: NSImage?
    nonisolated init(_ value: NSImage?) { self.value = value }
}

@MainActor
final class PhotoThumbnailCache {
    static let shared = PhotoThumbnailCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }

        let boxed = await Task.detached(priority: .utility) {
            ThumbnailBox(PhotoThumbnailCache.makeThumbnail(url: url, maxPixel: 240))
        }.value

        let made = boxed.value
        if let made { cache.setObject(made, forKey: url as NSURL) }
        return made
    }

    nonisolated private static func makeThumbnail(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]

        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - PhotosView

struct PhotosView: View {
    // ✅ [공유 모델] 앱 레벨에서 주입된 동일 인스턴스를 사용
    @EnvironmentObject private var viewModel: PhotoScannerViewModel

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                if viewModel.scanFolderURL == nil {
                    folderSelectionSection
                } else if viewModel.isScanning {
                    scanningSection
                } else if viewModel.hasResults {
                    resultsSection
                } else {
                    emptySection
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("photos.title".localized)
                    .font(.largeTitle.bold())
                Text("photos.subtitle".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if viewModel.scanFolderURL != nil {
                if viewModel.isScanning {
                    Button {
                        viewModel.cancelScan()
                    } label: {
                        Text("common.cancel".localized)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button {
                        viewModel.scan()
                    } label: {
                        Label("photos.action.scan".localized, systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("s", modifiers: [.command])
                }
            }
        }
    }

    // MARK: - Folder selection

    private var folderSelectionSection: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("photos.scope.select_hint".localized)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                viewModel.selectFolder()
            } label: {
                Label("common.select".localized, systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var folderBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
            Text(viewModel.selectedFolderPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("common.change".localized) {
                viewModel.selectFolder()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Scanning

    private var scanningSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            folderBar

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.phase.displayText)
                        .font(.headline)
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .cancel) {
                    viewModel.cancelScan()
                } label: {
                    Label("photos.action.stop".localized, systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            folderBar

            // 요약 바
            HStack(spacing: 16) {
                Label {
                    Text("photos.summary.count".localized(with: viewModel.totalCount))
                        .font(.caption.bold())
                } icon: {
                    Image(systemName: "photo.stack")
                        .foregroundStyle(.blue)
                }
                Label {
                    Text("photos.summary.size".localized(with: viewModel.totalSizeString))
                        .font(.caption.bold())
                } icon: {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let date = viewModel.lastScanDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // 카테고리 필터 바 (2단계: 전체 / 스크린샷 활성, 유사/흐릿은 곧)
            categoryFilterBar

            // 안내(남은 분류는 추후 단계)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("photos.note.detection_coming".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

            // 썸네일 그리드 (선택된 카테고리로 필터링)
            if viewModel.selectedCategory == .blurry && !viewModel.isBlurAnalyzed {
                blurAnalysisSection
            } else if viewModel.filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("photos.filter.empty".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewModel.filteredItems) { item in
                        PhotoThumbnailCell(item: item)
                            .onTapGesture(count: 2) {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Blur analysis (3단계, 주문형)

    @ViewBuilder
    private var blurAnalysisSection: some View {
        if viewModel.isAnalyzingBlur {
            VStack(spacing: 14) {
                ProgressView(value: viewModel.blurProgress)
                    .frame(maxWidth: 280)
                Text("photos.blur.analyzing".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .cancel) {
                    viewModel.cancelBlurAnalysis()
                } label: {
                    Label("photos.action.stop".localized, systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(40)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("photos.blur.prompt.title".localized)
                    .font(.headline)
                Text("photos.blur.prompt.desc".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    viewModel.analyzeBlur()
                } label: {
                    Label("photos.blur.prompt.button".localized, systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    // MARK: - Category filter

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoCategory.allCases) { category in
                    categoryPill(category)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func categoryPill(_ category: PhotoCategory) -> some View {
        let isReady = viewModel.readyCategories.contains(category)
        let isSelected = isReady && viewModel.selectedCategory == category

        return Button {
            if isReady { viewModel.selectedCategory = category }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.caption)
                Text(category.title)
                    .font(.caption.weight(.medium))
                if category == .blurry && !viewModel.isBlurAnalyzed {
                    Image(systemName: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if isReady {
                    Text("\(viewModel.count(for: category))")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                } else {
                    Text("photos.category.soon".localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                Capsule().stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                 lineWidth: isSelected ? 1.5 : 0.5)
            )
            .foregroundStyle(isSelected ? Color.accentColor : (isReady ? Color.primary : Color.secondary))
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.55)
        .help(isReady ? category.title : "photos.category.soon".localized)
    }

    // MARK: - Empty

    private var emptySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            folderBar

            VStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("photos.empty.title".localized)
                    .font(.headline)
                Text("photos.empty.desc".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}

// MARK: - Thumbnail cell

private struct PhotoThumbnailCell: View {
    let item: PhotoItem
    @State private var image: NSImage?
    @State private var didFinishLoading = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if didFinishLoading {
                    // ✅ 로드 실패 → 무한 스피너 대신 명확한 실패 표시
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .overlay(alignment: .topLeading) {
                if item.isScreenshot {
                    Image(systemName: "camera.viewfinder")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(Color.accentColor))
                        .padding(4)
                        .help("photos.category.screenshot".localized)
                }
            }

            Text(item.sizeString)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(item.name)
        .task(id: item.id) {
            didFinishLoading = false
            image = await PhotoThumbnailCache.shared.image(for: item.url)
            didFinishLoading = true
        }
    }
}

#Preview {
    PhotosView()
        .environmentObject(PhotoScannerViewModel())
        .frame(width: 960, height: 720)
}
