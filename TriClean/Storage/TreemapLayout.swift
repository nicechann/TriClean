//
//  TreemapLayout.swift
//  TriClean
//
//  Squarified Treemap 레이아웃 엔진
//  참조: Bruls, Huizing, van Wijk (2000)
//  "Squarified Treemaps"
//

import Foundation
import CoreGraphics

// MARK: - 트리맵 아이템 모델

struct TreemapItem: Identifiable {
    let id: UUID
    let name: String
    let path: String
    let url: URL
    let sizeBytes: Int64
    let isDirectory: Bool
    let colorIndex: Int
    let depth: Int
    
    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    
    /// FolderInfo에서 변환
    init(from folder: FolderInfo, colorIndex: Int) {
        self.id = folder.id
        self.name = folder.name
        self.path = folder.path
        self.url = folder.url
        self.sizeBytes = folder.sizeBytes
        self.isDirectory = folder.isDirectory
        self.colorIndex = colorIndex
        self.depth = folder.depth
    }
}

// MARK: - 레이아웃 결과

struct TreemapRect: Identifiable {
    let id: UUID
    let item: TreemapItem
    let rect: CGRect
}

// MARK: - Squarified Treemap 엔진

enum TreemapEngine {
    
    /// FolderInfo 배열을 트리맵 레이아웃으로 변환
    /// - Parameters:
    ///   - folders: depth==0 인 상위 폴더/파일 목록
    ///   - bounds: 트리맵을 그릴 영역
    ///   - padding: 각 셀 사이 여백 (기본 2px)
    /// - Returns: 각 아이템의 위치와 크기
    static func layout(
        folders: [FolderInfo],
        in bounds: CGRect,
        padding: CGFloat = 2
    ) -> [TreemapRect] {
        // depth==0이고 크기가 있는 항목만
        let topLevel = folders.filter { $0.depth == 0 && $0.sizeBytes > 0 }
        guard !topLevel.isEmpty else { return [] }
        
        // TreemapItem으로 변환 (색상 인덱스 부여)
        let items = topLevel
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .enumerated()
            .map { TreemapItem(from: $1, colorIndex: $0) }
        
        let totalSize = Double(items.reduce(Int64(0)) { $0 + $1.sizeBytes })
        guard totalSize > 0 else { return [] }
        
        // 면적 비율 계산
        let totalArea = Double(bounds.width * bounds.height)
        let areas = items.map { Double($0.sizeBytes) / totalSize * totalArea }
        
        var result: [TreemapRect] = []
        result.reserveCapacity(items.count)
        
        squarify(
            items: Array(zip(items, areas)),
            remaining: bounds,
            padding: padding,
            result: &result
        )
        
        return result
    }
    
    // MARK: - 핵심 알고리즘
    
    private static func squarify(
        items: [(TreemapItem, Double)],
        remaining: CGRect,
        padding: CGFloat,
        result: inout [TreemapRect]
    ) {
        guard !items.isEmpty else { return }
        guard remaining.width > 4, remaining.height > 4 else { return }
        
        // 아이템이 1개면 바로 배치
        if items.count == 1 {
            let (item, _) = items[0]
            let padded = remaining.insetBy(dx: padding, dy: padding)
            guard padded.width > 0, padded.height > 0 else { return }
            result.append(TreemapRect(id: item.id, item: item, rect: padded))
            return
        }
        
        let isHorizontal = remaining.width >= remaining.height
        let side = Double(isHorizontal ? remaining.height : remaining.width)
        guard side > 0 else { return }
        
        // 현재 행(row)에 넣을 아이템 결정
        var row: [(TreemapItem, Double)] = []
        var rowArea: Double = 0
        var bestAspect = Double.infinity
        var splitIdx = 0
        
        for i in 0..<items.count {
            let (item, area) = items[i]
            let testRow = row + [(item, area)]
            let testArea = rowArea + area
            
            let worst = worstAspect(
                areas: testRow.map(\.1),
                totalArea: testArea,
                side: side
            )
            
            if worst <= bestAspect {
                row = testRow
                rowArea = testArea
                bestAspect = worst
                splitIdx = i + 1
            } else {
                break
            }
        }
        
        // 현재 행 배치
        let rowLength = rowArea / side
        var offset: CGFloat = 0
        
        for (item, area) in row {
            let itemLength = area / rowLength
            
            let cellRect: CGRect
            if isHorizontal {
                cellRect = CGRect(
                    x: remaining.minX + padding,
                    y: remaining.minY + offset + padding,
                    width: CGFloat(rowLength) - padding * 2,
                    height: CGFloat(itemLength) - padding * 2
                )
            } else {
                cellRect = CGRect(
                    x: remaining.minX + offset + padding,
                    y: remaining.minY + padding,
                    width: CGFloat(itemLength) - padding * 2,
                    height: CGFloat(rowLength) - padding * 2
                )
            }
            
            if cellRect.width > 0, cellRect.height > 0 {
                result.append(TreemapRect(id: item.id, item: item, rect: cellRect))
            }
            offset += CGFloat(itemLength)
        }
        
        // 나머지 영역에 재귀
        let newRemaining: CGRect
        if isHorizontal {
            newRemaining = CGRect(
                x: remaining.minX + CGFloat(rowLength),
                y: remaining.minY,
                width: remaining.width - CGFloat(rowLength),
                height: remaining.height
            )
        } else {
            newRemaining = CGRect(
                x: remaining.minX,
                y: remaining.minY + CGFloat(rowLength),
                width: remaining.width,
                height: remaining.height - CGFloat(rowLength)
            )
        }
        
        if splitIdx < items.count {
            squarify(
                items: Array(items[splitIdx...]),
                remaining: newRemaining,
                padding: padding,
                result: &result
            )
        }
    }
    
    /// 행 내 가장 나쁜(정사각형에서 먼) 종횡비 계산
    private static func worstAspect(areas: [Double], totalArea: Double, side: Double) -> Double {
        guard !areas.isEmpty, side > 0, totalArea > 0 else { return .infinity }
        
        let rowLength = totalArea / side
        guard rowLength > 0 else { return .infinity }
        
        var worst: Double = 0
        for area in areas {
            let w = area / rowLength
            let h = rowLength
            guard w > 0, h > 0 else { continue }
            let ratio = max(w / h, h / w)
            worst = max(worst, ratio)
        }
        return worst
    }
}
