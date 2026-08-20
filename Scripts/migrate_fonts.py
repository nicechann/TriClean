#!/usr/bin/env python3
"""
.font(...) → .appFont(...) 일괄 변환 + .caption 오용 교정.

배경
  macOS에는 Dynamic Type이 없어 시맨틱 스타일이 사용자 설정에 반응하지 않는다.
  AppTypography가 자체 타입 스케일을 제공하므로, 기존 .font(...) 호출을
  .appFont(...)로 옮겨야 설정이 실제로 반영된다.

  동시에 .caption 오용을 바로잡는다. 변환 전 기준으로 폰트 지정 250곳 중
  138곳(55%)이 .caption/.caption2였고, 그중 상당수가 캡션이 아니라
  설명문·안내문·상태 메시지였다. macOS에서 caption은 10pt로 본문(13pt)보다
  3pt 작다. 설정을 추가해도 기본값이 10pt면 설정을 건드리지 않는 사용자에게는
  개선이 없으므로, 본문 성격의 자리를 .callout(12pt)으로 올린다.

동작
  1) .font(.<style>[.수식어…]) 를 .appFont(.<style>, …) 로 변환
  2) .font(.system(size: N[, weight: .w])) 는 대상 View를 확인해 변환
     - Text/Label → .appFont(size: N[, weight: .w])
     - Image      → .appIconFont(N[, weight: .w])
     - 대상 불명   → 자동 변환하지 않고 수동 확인 목록에 남김
  3) 승격 대상 로컬라이제이션 키를 쓰는 caption 자리를 callout으로 승격

  변환하지 않는 것 — 계산된 크기(.system(size: 함수호출)), design이 명시된
  .system(.caption, design:), 삼항 연산자가 섞인 표현식. 목록으로 보고하니
  수동 처리할 것.

사용법
  python3 Scripts/migrate_fonts.py --dry-run     # 변경 없이 리포트만
  python3 Scripts/migrate_fonts.py               # 실제 적용
  git diff                                       # 반드시 검토할 것
"""

import argparse
import os
import re
import sys

SOURCE_ROOT = "TriClean"

# 자체 폰트 시스템을 정의하는 파일이라 변환에서 제외한다.
EXCLUDED = {"AppTypography.swift"}

STYLES = [
    "largeTitle", "title3", "title2", "title", "headline",
    "subheadline", "body", "callout", "footnote", "caption2", "caption",
]

# .font(.<style><chain>) — chain 예: .bold() / .weight(.semibold) / .monospacedDigit()
FONT_CALL = re.compile(
    r"\.font\(\s*\.(" + "|".join(STYLES) + r")((?:\.[a-zA-Z]+\([^()]*\))*)\s*\)"
)

# .font(.system(size: 36)) / .font(.system(size: 28, weight: .semibold))
SYSTEM_CALL = re.compile(
    r"\.font\(\s*\.system\(size:\s*(\d+(?:\.\d+)?)"
    r"(?:,\s*weight:\s*\.([a-zA-Z]+))?\s*\)\s*\)"
)

# 승격 대상: 본문·설명 성격의 로컬라이제이션 키 접미사.
# 파일 경로나 용량 수치처럼 부가 정보인 자리는 caption으로 남긴다.
PROMOTE_SUFFIXES = {
    "desc", "description", "subtitle", "hint", "note", "tip", "body",
    "notice", "empty", "analyzing", "denied", "warning",
    "wrong_path_warning", "select_library_hint", "access_desc",
    "menubar_unit_desc", "app_activation_desc", "toggle_desc",
    "clean_desc", "search_desc", "detection_coming", "soon",
}

TEXT_CALL = re.compile(r"\b(?:Text|Label)\s*\(")
VIEW_CALL = re.compile(r"\b(Text|Label|Image)\s*\(")
LOC_KEY = re.compile(r'"([a-z0-9_]+(?:\.[a-z0-9_]+)+)"')


def convert_chain(chain):
    """.bold().monospacedDigit() 같은 수식어 체인을 appFont 인자로 바꾼다."""
    args = []
    unknown = []
    for name, inner in re.findall(r"\.([a-zA-Z]+)\(([^()]*)\)", chain):
        if name == "bold":
            args.append("weight: .bold")
        elif name == "weight":
            args.append(f"weight: {inner.strip()}")
        elif name == "monospacedDigit":
            args.append("monospacedDigit: true")
        elif name == "italic":
            args.append("italic: true")
        else:
            unknown.append(name)
    return args, unknown


def promotion_target(lines, index):
    """해당 줄 위쪽에서 가장 가까운 Text(/Label( 의 로컬라이제이션 키를 찾는다."""
    for j in range(index, max(-1, index - 6), -1):
        if TEXT_CALL.search(lines[j]):
            match = LOC_KEY.search(lines[j])
            if not match:
                return None
            return match.group(1).split(".")[-1]
    return None


def fixed_size_target(lines, index):
    """고정 크기 font가 Text/Label인지 Image인지 가까운 View 생성자에서 판별한다."""
    for j in range(index, max(-1, index - 8), -1):
        match = VIEW_CALL.search(lines[j])
        if match:
            return match.group(1)
        # 체인이 끝난 뒤 다른 문장으로 넘어가면 엉뚱한 View를 잡지 않는다.
        if j < index and lines[j].strip() == "":
            break
    return None


def process(path, promote, report):
    with open(path, encoding="utf-8") as handle:
        original = handle.read()

    lines = original.split("\n")
    out = []
    changed = 0

    for index, line in enumerate(lines):
        new_line = line

        def replace_font(match):
            nonlocal changed
            style = match.group(1)
            args, unknown = convert_chain(match.group(2) or "")
            if unknown:
                report["manual"].append(
                    f"{path}:{index + 1}  미지원 수식어 {unknown} — 수동 확인"
                )
                return match.group(0)

            if promote and style in ("caption", "caption2"):
                suffix = promotion_target(lines, index)
                if suffix in PROMOTE_SUFFIXES:
                    report["promoted"].append(f"{path}:{index + 1}  .{style} → .callout")
                    style = "callout"

            changed += 1
            joined = "".join(", " + a for a in args)
            return f".appFont(.{style}{joined})"

        def replace_system(match):
            nonlocal changed
            size = match.group(1)
            weight = match.group(2)
            target = fixed_size_target(lines, index)

            if target in ("Text", "Label"):
                changed += 1
                if weight:
                    return f".appFont(size: {size}, weight: .{weight})"
                return f".appFont(size: {size})"

            if target == "Image":
                changed += 1
                if weight:
                    return f".appIconFont({size}, weight: .{weight})"
                return f".appIconFont({size})"

            report["manual"].append(
                f"{path}:{index + 1}  고정 크기 폰트 대상 View를 판별하지 못함 — 수동 확인"
            )
            return match.group(0)

        new_line = FONT_CALL.sub(replace_font, new_line)
        new_line = SYSTEM_CALL.sub(replace_system, new_line)

        # 변환되지 않고 남은 .font( 는 수동 처리 대상으로 보고한다.
        if ".font(" in new_line:
            report["manual"].append(f"{path}:{index + 1}  {new_line.strip()[:88]}")

        out.append(new_line)

    return "\n".join(out), changed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", help="변경 없이 리포트만 출력")
    parser.add_argument(
        "--no-promote",
        action="store_true",
        help="caption → callout 승격을 건너뛴다 (기계적 변환만)",
    )
    args = parser.parse_args()

    if not os.path.isdir(SOURCE_ROOT):
        sys.exit(f"{SOURCE_ROOT}/ 를 찾을 수 없습니다. 저장소 루트에서 실행하세요.")

    report = {"promoted": [], "manual": []}
    total_files = 0
    total_changes = 0

    for root, _, files in os.walk(SOURCE_ROOT):
        for name in sorted(files):
            if not name.endswith(".swift") or name in EXCLUDED:
                continue
            path = os.path.join(root, name)
            with open(path, encoding="utf-8") as handle:
                before = handle.read()

            after, changed = process(path, not args.no_promote, report)
            if changed and after != before:
                total_files += 1
                total_changes += changed
                if not args.dry_run:
                    with open(path, "w", encoding="utf-8") as handle:
                        handle.write(after)

    print(f"변환: {total_changes}곳 / {total_files}개 파일")
    print(f"caption → callout 승격: {len(report['promoted'])}곳")

    if report["promoted"]:
        print("\n[승격된 자리]")
        for entry in report["promoted"]:
            print(f"  {entry}")

    if report["manual"]:
        print(f"\n[수동 처리 필요 — {len(report['manual'])}곳]")
        for entry in report["manual"]:
            print(f"  {entry}")

    if args.dry_run:
        print("\n※ --dry-run 이므로 파일은 변경되지 않았습니다.")
    else:
        print("\n적용 완료. 반드시 git diff 로 검토한 뒤 빌드하세요.")


if __name__ == "__main__":
    main()
