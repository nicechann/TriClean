//
//  QuickLookPreview.swift
//  TriClean
//
//  삭제 판단 직전에 파일 내용을 확인할 수 있게 하는 미리보기.
//
//  이 앱의 핵심 가치는 "안전하게 지운다"인데, 대용량 파일·중복 파일 화면은
//  이름과 경로만 보여줬다. 무엇을 지우는지 볼 수 없으면 사용자는 매번 Finder로
//  나갔다 돌아와야 하고, 그 마찰이 곧 잘못 지울 위험이 된다.
//
//  ⚠️ 구현 선택: `QLPreviewPanel`(스페이스바 방식)이 아니라 `QLPreviewView`를 쓴다.
//    `QLPreviewPanel`은 응답자 체인(responder chain)에 컨트롤러가 있어야 동작하는데,
//    SwiftUI `Table` 안에서는 그 체인을 안정적으로 잡기 어렵다.
//    `QLPreviewView`를 시트에 직접 심으면 체인에 의존하지 않는다.
//
//  ⚠️ 샌드박스: 미리보기는 파일을 **읽는다**. 호출부가 해당 폴더의 보안 스코프 접근을
//    유지하고 있어야 내용이 표시된다(`SecurityScopedAccessToken`).
//

import SwiftUI
import AppKit
import QuickLookUI

/// `QLPreviewView`를 SwiftUI에 올리는 래퍼.
///
/// ⚠️ `QLPreviewView(frame:style:)`는 실패 가능 이니셜라이저다. 강제 언래핑 대신
///   컨테이너 뷰에 담아, 생성에 실패해도 빈 영역만 보이고 앱은 계속 동작하게 한다.
struct QuickLookPreview: NSViewRepresentable {

    let url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)

        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            return container
        }

        preview.autostarts = true
        preview.previewItem = url as NSURL
        context.coordinator.loadedURL = url

        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let preview = nsView.subviews.first as? QLPreviewView else { return }
        // 같은 URL을 다시 넣으면 미리보기가 다시 로드되며 깜빡이므로 바뀐 경우에만 갱신한다.
        guard context.coordinator.loadedURL != url else { return }
        preview.previewItem = url as NSURL
        context.coordinator.loadedURL = url
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // 명시적으로 닫지 않으면 미리보기가 파일 핸들을 붙들고 있을 수 있다.
        (nsView.subviews.first as? QLPreviewView)?.close()
    }
}

/// 파일 하나를 미리 보는 시트. 이름·경로·크기를 함께 보여준다.
struct QuickLookPreviewSheet: View {

    let target: QuickLookTarget
    let onDismiss: () -> Void

    private var url: URL { target.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .appFont(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(url.deletingLastPathComponent().path)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                if let sizeText = target.sizeText {
                    Text(sizeText)
                        .appFont(.subheadline, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("common.finder_app".localized, systemImage: "folder")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("common.finder".localized)
                .accessibilityLabel(Text("common.finder".localized))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            QuickLookPreview(url: url)
                .frame(minWidth: 520, minHeight: 360)

            Divider()

            HStack {
                Spacer()
                Button("common.close".localized) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 560, minHeight: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("common.preview".localized))
    }
}

/// 미리보기 대상. `.sheet(item:)`에 바로 쓸 수 있도록 `Identifiable`을 만족시킨다.
nonisolated struct QuickLookTarget: Identifiable, Hashable, Sendable {
    let url: URL
    let sizeText: String?

    var id: String { url.path }

    init(url: URL, sizeText: String? = nil) {
        self.url = url
        self.sizeText = sizeText
    }
}
