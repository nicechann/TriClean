//
//  TreemapView.swift
//  TriClean
//
//  DaisyDisk 스타일 인터랙티브 트리맵 시각화
//
//  사용법 (StorageView 내에서):
//    TreemapView(
//        items: viewModel.folderResults,
//        onItemTapped: { item in viewModel.openInFinder(item) }
//    )
//

import SwiftUI

// MARK: - 색상 팔레트

private let treemapPalette: [Color] = [
    Color(red: 0.33, green: 0.68, blue: 0.89),  // Blue
    Color(red: 0.43, green: 0.84, blue: 0.41),  // Green
    Color(red: 0.99, green: 0.71, blue: 0.31),  // Orange
    Color(red: 0.69, green: 0.48, blue: 1.0),   // Purple
    Color(red: 0.98, green: 0.46, blue: 0.33),  // Coral
    Color(red: 0.36, green: 0.78, blue: 0.65),  // Teal
    Color(red: 0.95, green: 0.55, blue: 0.66),  // Pink
    Color(red: 0.80, green: 0.73, blue: 0.35),  // Olive
    Color(red: 0.55, green: 0.63, blue: 0.80),  // Slate
    Color(red: 0.85, green: 0.55, blue: 0.40),  // Tan
]

// MARK: - 트리맵 뷰

struct TreemapView: View {
    let items: [FolderInfo]
    var onItemTapped: ((FolderInfo) -> Void)? = nil
    
    @State private var hoveredID: UUID? = nil
    @State private var selectedItem: FolderInfo? = nil
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 헤더
            HStack(alignment: .top) {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("storage.treemap.title".localized)
                        .font(.headline)
                    Text("storage.treemap.subtitle".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let item = selectedItem {
                    HStack(spacing: 6) {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.name)
                            .font(.caption.bold())
                        Text(item.sizeString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
            
            // 트리맵 캔버스
            GeometryReader { geo in
                let rects = TreemapEngine.layout(
                    folders: items,
                    in: CGRect(origin: .zero, size: geo.size),
                    padding: 2
                )
                
                ZStack(alignment: .topLeading) {
                    // 배경
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                    
                    // 트리맵 셀
                    ForEach(rects) { layoutRect in
                        treemapCell(layoutRect, containerSize: geo.size)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
            }
            .frame(minHeight: 200, idealHeight: 280, maxHeight: 400)
            
            // 범례
            treemapLegend

            if selectedItem == nil {
                Text("storage.treemap.hint".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - 셀 렌더링
    
    @ViewBuilder
    private func treemapCell(_ layoutRect: TreemapRect, containerSize: CGSize) -> some View {
        let item = layoutRect.item
        let rect = layoutRect.rect
        let isHovered = hoveredID == item.id
        let color = treemapPalette[item.colorIndex % treemapPalette.count]
        let canShowLabel = rect.width > 50 && rect.height > 24
        let canShowSize = rect.width > 60 && rect.height > 38
        
        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(isHovered ? 0.95 : 0.75))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isHovered ? Color.white.opacity(0.8) : color.opacity(0.3),
                        lineWidth: isHovered ? 2 : 0.5
                    )
            )
            .overlay(
                VStack(spacing: 2) {
                    if canShowLabel {
                        Text(item.name)
                            .font(.system(size: labelFontSize(for: rect), weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                    }
                    if canShowSize {
                        Text(item.sizeString)
                            .font(.system(size: max(9, labelFontSize(for: rect) - 2)))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                    }
                }
                .padding(4)
            )
            .frame(width: max(0, rect.width), height: max(0, rect.height))
            .position(x: rect.midX, y: rect.midY)
            .onHover { inside in
                withAnimation(.easeInOut(duration: 0.15)) {
                    hoveredID = inside ? item.id : nil
                }
            }
            .onTapGesture {
                selectedItem = items.first { $0.id == item.id }
                if let folder = items.first(where: { $0.id == item.id }) {
                    onItemTapped?(folder)
                }
            }
            .help("storage.treemap.item_help".localized(with: item.name, item.sizeString))
    }
    
    private func labelFontSize(for rect: CGRect) -> CGFloat {
        let area = rect.width * rect.height
        if area > 20000 { return 13 }
        if area > 8000 { return 11 }
        if area > 3000 { return 10 }
        return 9
    }
    
    // MARK: - 범례
    
    private var treemapLegend: some View {
        let topItems = items
            .filter { $0.depth == 0 && $0.sizeBytes > 0 }
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(8)
        
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(topItems.enumerated()), id: \.element.id) { idx, item in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(treemapPalette[idx % treemapPalette.count].opacity(0.75))
                            .frame(width: 10, height: 10)
                        Text(item.name)
                            .lineLimit(1)
                        Text(item.sizeString)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }
            }
        }
    }
}

// MARK: - StorageView에 통합하는 방법
//
// StorageView.swift의 resultsTableSection 위에 아래 코드를 추가:
//
// ```swift
// if !folderResults.isEmpty {
//     TreemapView(
//         items: folderResults,
//         onItemTapped: { item in openInFinder(item) }
//     )
//     .padding(.horizontal, 12)
//
//     Divider()
// }
// ```

#Preview {
    let sampleItems: [FolderInfo] = [
        FolderInfo(url: URL(fileURLWithPath: "/Users/test/Downloads"), sizeBytes: 5_000_000_000, isDirectory: true),
        FolderInfo(url: URL(fileURLWithPath: "/Users/test/Documents"), sizeBytes: 3_200_000_000, isDirectory: true),
        FolderInfo(url: URL(fileURLWithPath: "/Users/test/Library"), sizeBytes: 2_800_000_000, isDirectory: true),
        FolderInfo(url: URL(fileURLWithPath: "/Users/test/Desktop"), sizeBytes: 1_500_000_000, isDirectory: true),
        FolderInfo(url: URL(fileURLWithPath: "/Users/test/Movies"), sizeBytes: 800_000_000, isDirectory: true),
        FolderInfo(url: URL(fileURLWithPath: "/Users/test/bigfile.zip"), sizeBytes: 600_000_000, isDirectory: false),
    ]
    
    TreemapView(items: sampleItems)
        .frame(width: 700, height: 400)
        .padding()
}
