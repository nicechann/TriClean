//
//  AppTypography.swift
//  TriClean
//
//  앱 전역 글자 크기·서체 설정.
//
//  macOS에는 Dynamic Type이 없다. iOS/iPadOS 등과 달리 시스템이 사용자 선호
//  텍스트 크기를 SwiftUI의 시맨틱 스타일(.body, .caption 등)에 반영해 주지 않으므로,
//  앱이 직접 타입 스케일을 계산해야 한다. 이 파일이 그 역할을 한다.
//
//  사용법
//      Text("...").appFont(.body)
//      Text("...").appFont(.caption, weight: .bold)
//      Text("...").appFont(.body, monospacedDigit: true)
//
//  .font(...) 대신 .appFont(...)을 쓰면 설정의 크기 배율과 서체가 자동 적용된다.
//

import SwiftUI

// MARK: - 서체 디자인

/// 사용자가 고를 수 있는 서체.
///
/// 임의의 시스템 폰트를 열어주지 않고 SF 계열 디자인 변형만 노출한다.
/// TriClean은 14개 언어를 지원하므로, 한글·중국어·일본어·키릴·그리스 글리프를
/// 갖추지 못한 서체를 허용하면 폰트 폴백이 일어나 한 화면에서 서체가 뒤섞인다.
/// `Font.Design`은 모두 시스템 서체 계열이라 이 문제가 없다.
enum AppFontDesign: String, CaseIterable, Identifiable, Sendable {
    case standard
    case rounded
    case monospaced
    case serif

    var id: String { rawValue }

    var design: Font.Design {
        switch self {
        case .standard: return .default
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        case .serif: return .serif
        }
    }

    var localizationKey: String { "settings.typography.design.\(rawValue)" }
}

// MARK: - 크기 배율

/// 글자 크기 배율.
///
/// 연속 슬라이더 대신 단계로 제공한다. 고정 폭(`frame(width:)`)이 잡힌 화면이
/// 많아 임의 배율을 허용하면 레이아웃이 깨지는 지점을 예측할 수 없다.
enum AppFontScale: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large
    case extraLarge

    var id: String { rawValue }

    var multiplier: CGFloat {
        switch self {
        case .small: return 0.9
        case .standard: return 1.0
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }

    var localizationKey: String { "settings.typography.scale.\(rawValue)" }
}

// MARK: - 설정 값

struct AppTypography: Equatable, Sendable {
    var scale: AppFontScale = .standard
    var design: AppFontDesign = .standard

    /// UserDefaults 키. SettingsView와 TriCleanApp이 공유한다.
    enum StorageKey {
        static let scale = "appFontScale"
        static let design = "appFontDesign"
    }

    /// 저장된 문자열에서 복원한다. 알 수 없는 값은 기본값으로 떨어진다.
    static func resolve(scaleRawValue: String, designRawValue: String) -> AppTypography {
        AppTypography(
            scale: AppFontScale(rawValue: scaleRawValue) ?? .standard,
            design: AppFontDesign(rawValue: designRawValue) ?? .standard
        )
    }
}

// MARK: - Environment

private struct AppTypographyKey: EnvironmentKey {
    // EnvironmentKey의 요구사항은 nonisolated다. 이 타깃은
    // SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor로 빌드되므로 명시해야 한다.
    nonisolated static let defaultValue = AppTypography()
}

extension EnvironmentValues {
    var appTypography: AppTypography {
        get { self[AppTypographyKey.self] }
        set { self[AppTypographyKey.self] = newValue }
    }
}

// MARK: - 기준 크기표

extension Font.TextStyle {
    /// macOS 기준 시스템 폰트 포인트 크기.
    ///
    /// iOS와 값이 다르다. 특히 macOS에서는 footnote·caption·caption2가 모두 10pt로
    /// 동일하므로, 이 셋 사이에는 크기 위계가 없고 색·굵기로만 구분된다.
    var triCleanBaseSize: CGFloat {
        switch self {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline: return 13
        case .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote: return 10
        case .caption: return 10
        case .caption2: return 10
        @unknown default: return 13
        }
    }

    /// 시맨틱 스타일이 원래 갖는 굵기. `.headline`만 semibold다.
    var triCleanDefaultWeight: Font.Weight {
        self == .headline ? .semibold : .regular
    }
}

// MARK: - Modifier

struct AppFontModifier: ViewModifier {
    @Environment(\.appTypography) private var typography

    let style: Font.TextStyle
    let weight: Font.Weight?
    let monospacedDigit: Bool
    let italic: Bool

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        var font = Font.system(
            size: resolvedSize,
            weight: weight ?? style.triCleanDefaultWeight,
            design: typography.design.design
        )
        if monospacedDigit { font = font.monospacedDigit() }
        if italic { font = font.italic() }
        return font
    }

    /// 0.5pt 단위로 반올림한다. 소수점이 그대로 남으면 행 높이가 배수마다
    /// 미세하게 어긋나 목록에서 정렬이 흔들린다.
    private var resolvedSize: CGFloat {
        let raw = style.triCleanBaseSize * typography.scale.multiplier
        return (raw * 2).rounded() / 2
    }
}

extension View {
    /// 설정의 크기 배율과 서체가 반영된 시맨틱 폰트를 적용한다.
    ///
    /// `.font(...)`의 대체재다. 새 코드에서는 `.font(...)`를 직접 쓰지 말 것.
    /// - Parameters:
    ///   - style: 시맨틱 텍스트 스타일.
    ///   - weight: 굵기를 덮어쓴다. nil이면 스타일 기본값을 따른다.
    ///   - monospacedDigit: 숫자 폭을 고정한다. 실시간 갱신되는 수치에 쓴다.
    ///   - italic: 기울임.
    func appFont(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        monospacedDigit: Bool = false,
        italic: Bool = false
    ) -> some View {
        modifier(
            AppFontModifier(
                style: style,
                weight: weight,
                monospacedDigit: monospacedDigit,
                italic: italic
            )
        )
    }
}

// MARK: - 고정 크기 텍스트

struct AppFixedFontModifier: ViewModifier {
    @Environment(\.appTypography) private var typography

    let size: CGFloat
    let weight: Font.Weight
    let monospacedDigit: Bool
    let italic: Bool

    func body(content: Content) -> some View {
        var font = Font.system(
            size: resolvedSize,
            weight: weight,
            design: typography.design.design
        )
        if monospacedDigit { font = font.monospacedDigit() }
        if italic { font = font.italic() }
        return content.font(font)
    }

    private var resolvedSize: CGFloat {
        let raw = size * typography.scale.multiplier
        return (raw * 2).rounded() / 2
    }
}

extension View {
    /// 타이틀·배지처럼 시맨틱 스타일 대신 포인트 크기를 직접 써야 하는 텍스트용.
    /// 크기 배율과 사용자가 고른 서체 디자인을 모두 반영한다.
    func appFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        monospacedDigit: Bool = false,
        italic: Bool = false
    ) -> some View {
        modifier(
            AppFixedFontModifier(
                size: size,
                weight: weight,
                monospacedDigit: monospacedDigit,
                italic: italic
            )
        )
    }
}

// MARK: - 아이콘·고정 크기 보정

extension View {
    /// SF Symbol 등 포인트 크기를 직접 지정하는 아이콘에서 배율만 반영한다.
    /// 일반 Text/Label에는 `appFont(size:weight:)`를 사용해야 서체 설정도 반영된다.
    ///
    /// 글자 크기를 키웠는데 옆의 아이콘만 그대로면 균형이 무너지므로,
    /// `.font(.system(size: 36))` 같은 자리를 `.appIconFont(36)`으로 바꾼다.
    func appIconFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(AppIconFontModifier(size: size, weight: weight))
    }
}

struct AppIconFontModifier: ViewModifier {
    @Environment(\.appTypography) private var typography

    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        let scaled = (size * typography.scale.multiplier * 2).rounded() / 2
        return content.font(.system(size: scaled, weight: weight))
    }
}
