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
    @State private var isExpanded = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 섹션 헤더
            HStack(spacing: 8) {
                Image(systemName: "trash.circle")
                    .foregroundStyle(.orange)
                Text("Junk Files")
                    .font(.title3.bold())
                
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
                        Label("스캔", systemImage: "magnifyingglass")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            // ~/Library 경로 상태
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
                    Text("~/Library 폴더를 선택하면 정크 파일을 자동으로 찾습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(viewModel.libraryURL == nil ? "~/Library 선택" : "변경…") {
                    viewModel.selectLibraryFolder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            // 스캔 결과
            if viewModel.hasResults {
                // 총 용량 요약
                HStack(spacing: 16) {
                    Label {
                        Text("발견: \(viewModel.totalJunkString)")
                            .font(.caption.bold())
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    
                    Label {
                        Text("선택: \(viewModel.selectedJunkString)")
                            .font(.caption.bold())
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                    
                    Spacer()
                    
                    Button(role: .destructive) {
                        showCleanConfirm = true
                    } label: {
                        Label("정리", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(viewModel.selectedJunkBytes == 0)
                }
                .padding(.top, 4)
                
                // 카테고리 목록 (카드 형태)
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(viewModel.results) { result in
                        junkCategoryCard(result)
                    }
                }
                
                if let date = viewModel.lastScanDate {
                    Text("마지막 스캔: \(date.formatted(date: .abbreviated, time: .shortened))")
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
        .alert("선택한 정크 파일 정리", isPresented: $showCleanConfirm) {
            Button("휴지통으로 이동", role: .destructive) {
                viewModel.cleanSelected()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(viewModel.selectedJunkString)을 휴지통으로 이동합니다.\nFinder에서 복원할 수 있습니다.")
        }
    }
    
    // MARK: - 카테고리 카드
    
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
            
            // 위험도 뱃지
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
    }
}
