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
        .alert("중복 파일 정리", isPresented: $showDeleteConfirm) {
            Button("휴지통으로 이동", role: .destructive) {
                viewModel.deleteDuplicates()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("선택한 중복 파일을 휴지통으로 이동합니다.\n각 그룹에서 최소 1개 파일은 보존됩니다.")
        }
    }
    
    // MARK: - 헤더
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Duplicate Finder")
                    .font(.title2.bold())
                Text("동일한 내용의 중복 파일을 찾아 정리합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if viewModel.scanFolderURL != nil {
                // 최소 파일 크기 설정
                HStack(spacing: 4) {
                    Text("최소:")
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
                    Label("폴더 변경", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
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
    
    // MARK: - 폴더 선택
    
    private var folderSelectionSection: some View {
        GroupBox {
            VStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                
                Text("중복 파일을 찾을 폴더를 선택하세요")
                    .font(.headline)
                
                Text("선택한 폴더와 하위 폴더에서 동일한 내용의 파일을 찾습니다.\n파일 크기 → 부분 해시 → 전체 해시 3단계로 정확하게 비교합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Button("폴더 선택") {
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
                Text(viewModel.phase.rawValue)
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
    
    // MARK: - 결과
    
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 요약
            HStack(spacing: 16) {
                summaryCard(
                    title: "중복 그룹",
                    value: "\(viewModel.totalDuplicateGroups)개",
                    icon: "doc.on.doc.fill",
                    color: .orange
                )
                summaryCard(
                    title: "확보 가능 용량",
                    value: viewModel.totalReclaimableString,
                    icon: "externaldrive.badge.checkmark",
                    color: .green
                )
                summaryCard(
                    title: "스캔 파일",
                    value: "\(viewModel.totalFilesScanned)개",
                    icon: "doc.text.magnifyingglass",
                    color: .blue
                )
            }
            
            // 그룹 목록
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.groups) { group in
                        duplicateGroupRow(group)
                    }
                }
            }
            
            // 하단 액션
            HStack {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("중복 파일 정리 (\(viewModel.totalReclaimableString))", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(viewModel.groups.isEmpty)
            }
        }
    }
    
    // MARK: - 빈 상태
    
    private var emptySection: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text(viewModel.phase == .done ? "중복 파일이 없습니다" : "스캔 대기 중")
                .font(.headline)
            Text(viewModel.phase == .done
                 ? "선택한 폴더에서 중복 파일을 찾지 못했습니다."
                 : "'스캔' 버튼을 눌러 중복 파일을 찾아보세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    
    private func duplicateGroupRow(_ group: DuplicateGroup) -> some View {
        let isExpanded = expandedGroupIDs.contains(group.id)
        
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // 그룹 헤더
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
                            Text("\(group.files.count)개 동일 파일")
                                .font(.subheadline.bold())
                            Text("각 \(group.fileSizeString) · \(group.reclaimableString) 확보 가능")
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
                
                // 확장 시 파일 목록
                if isExpanded {
                    Divider()
                    
                    ForEach(group.files) { file in
                        HStack(spacing: 8) {
                            // 보존/삭제 토글
                            Button {
                                viewModel.toggleKeep(groupID: group.id, fileID: file.id)
                            } label: {
                                Image(systemName: file.isKeep ? "checkmark.shield.fill" : "xmark.circle")
                                    .foregroundStyle(file.isKeep ? .green : .red)
                            }
                            .buttonStyle(.plain)
                            .help(file.isKeep ? "보존 (클릭하면 삭제 대상으로 변경)" : "삭제 대상 (클릭하면 보존으로 변경)")
                            
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
                            
                            Text(file.isKeep ? "보존" : "삭제")
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
