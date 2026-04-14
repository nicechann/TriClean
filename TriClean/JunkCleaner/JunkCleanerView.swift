//
//  JunkCleanerView.swift
//  TriClean
//
//  정크 파일 자동 스캔 & 정리 화면
//  ContentView의 사이드바에 "Junk Cleaner" 항목으로 추가
//

import SwiftUI

struct JunkCleanerView: View {
    @StateObject private var viewModel = JunkScannerViewModel()
    @State private var showCleanConfirm = false
    @State private var expandedCategories: Set<String> = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            libraryScopeSection   // ✅ 항상 라이브러리 경로 상태 표시
            
            if viewModel.isScanning {
                scanningSection
            } else if viewModel.hasResults {
                resultsSection
            } else {
                emptySection
            }
            
            Spacer()
        }
        .padding()
        .alert("선택한 항목 정리", isPresented: $showCleanConfirm) {
            Button("휴지통으로 이동", role: .destructive) {
                viewModel.cleanSelected()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("선택한 정크 파일 \(viewModel.selectedJunkString)을 휴지통으로 이동합니다.\nFinder에서 복원할 수 있습니다.")
        }
    }
    
    // MARK: - 헤더
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Junk Cleaner")
                    .font(.title2.bold())
                Text("불필요한 캐시, 로그, 임시 파일을 찾아 정리합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // ✅ 라이브러리 선택 완료 시에만 스캔 버튼 표시
            if viewModel.libraryURL != nil {
                Button {
                    viewModel.scan()
                } label: {
                    Label("스캔", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isScanning)
            }
        }
    }
    
    // MARK: - ✅ 라이브러리 폴더 상태 (항상 표시)
    
    private var libraryScopeSection: some View {
        GroupBox {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: viewModel.libraryURL == nil ? "xmark.circle" : "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(viewModel.libraryURL == nil ? Color.secondary : Color.green)
                        .frame(width: 28)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Home Library (~/Library)")
                            .font(.subheadline.bold())
                        
                        if let url = viewModel.libraryURL {
                            Text(url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("정크 파일 스캔을 위해 ~/Library 폴더를 선택해 주세요.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    if viewModel.libraryURL == nil {
                        Button("~/Library 선택") {
                            viewModel.selectLibraryFolder()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("변경…") {
                            viewModel.selectLibraryFolder()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                
                if viewModel.libraryURL == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                        Text("선택한 폴더 범위 안에서만 스캔합니다. 시스템 파일은 건드리지 않습니다.")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    // MARK: - 스캔 중
    
    private var scanningSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(viewModel.scanProgress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    // MARK: - 스캔 결과
    
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 요약 카드
            HStack(spacing: 16) {
                summaryCard(
                    title: "발견된 정크",
                    value: viewModel.totalJunkString,
                    icon: "trash.circle",
                    color: .orange
                )
                summaryCard(
                    title: "선택된 항목",
                    value: viewModel.selectedJunkString,
                    icon: "checkmark.circle",
                    color: .blue
                )
            }
            
            // 카테고리별 결과
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.results) { result in
                        categoryRow(result)
                    }
                }
            }
            
            // 정리 버튼
            HStack {
                if let date = viewModel.lastScanDate {
                    Text("마지막 스캔: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    showCleanConfirm = true
                } label: {
                    Label("선택 항목 정리 (\(viewModel.selectedJunkString))", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(viewModel.selectedJunkBytes == 0)
            }
        }
    }
    
    // MARK: - 빈 상태
    
    private var emptySection: some View {
        VStack(spacing: 12) {
            if viewModel.libraryURL == nil {
                // ✅ 라이브러리 미선택 시 안내
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("~/Library 폴더를 먼저 선택해 주세요")
                    .font(.headline)
                Text("상단에서 '~/Library 선택' 버튼을 눌러\n스캔 범위를 지정하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                // ✅ 라이브러리 선택 완료, 스캔 대기
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text("스캔 준비 완료")
                    .font(.headline)
                Text("오른쪽 상단의 '스캔' 버튼을 눌러 정크 파일을 찾아보세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    // MARK: - 서브뷰
    
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
    
    private func categoryRow(_ result: JunkScanResult) -> some View {
        let isExpanded = expandedCategories.contains(result.id)
        
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // 헤더
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
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.category.name)
                                .font(.subheadline.bold())
                            Text(result.category.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        // 위험도 뱃지
                        Text(result.category.riskLevel.label)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(result.category.riskLevel.color.opacity(0.15))
                            )
                            .foregroundStyle(result.category.riskLevel.color)
                        
                        Text(result.totalString)
                            .font(.subheadline.monospacedDigit().bold())
                        
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                
                // 확장 시 상세 목록
                if isExpanded {
                    Divider()
                    
                    HStack {
                        Button("전체 선택") { viewModel.selectAll(in: result.id) }
                        Button("전체 해제") { viewModel.deselectAll(in: result.id) }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    ForEach(result.items.prefix(50)) { item in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: {
                                    viewModel.results
                                        .first(where: { $0.id == result.id })?
                                        .items.first(where: { $0.id == item.id })?
                                        .isSelected ?? false
                                },
                                set: { _ in viewModel.toggleItem(in: result.id, itemID: item.id) }
                            ))
                            .labelsHidden()
                            
                            Image(systemName: "doc")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Text(item.name)
                                .font(.caption)
                                .lineLimit(1)
                            
                            Spacer()
                            
                            Text(item.sizeString)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    if result.items.count > 50 {
                        Text("외 \(result.items.count - 50)개 항목...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

#Preview {
    JunkCleanerView()
        .frame(width: 800, height: 600)
}
