#!/usr/bin/env python3
"""
AppIcon.appiconset 재생성 — 레거시 macOS 아이콘셋 유지용.

배경
  Xcode 26 이상에서는 프로젝트의 AppIcon.icon(Icon Composer)을 주 아이콘으로
  사용한다. 이 스크립트는 기존 AppIcon.appiconset을 유지하거나 비교할 때 쓰는
  레거시 생성 도구다. 현재 레거시 아이콘은 1024pt 캔버스 안에 본체를
  824x824로 두고 사방에 여백을 남기는 기존 규격을 유지한다.

  최신 아이콘의 크기/마스킹 조정은 이 스크립트가 아니라
  TriClean/AppIcon.icon에서 관리한다.

사용법
  python3 Scripts/regenerate_app_icon.py <마스터.png>
  python3 Scripts/regenerate_app_icon.py <마스터.png> --shadow
  python3 Scripts/regenerate_app_icon.py <마스터.png> --out /tmp/preview

  마스터는 1024x1024 이상 권장. 알파 채널이 있어야 본체를 인식한다.
  --shadow 를 주면 Apple 기본 아이콘과 유사한 은은한 드롭섀도를 합성한다.
  (이미 그림자가 그려진 마스터라면 주지 말 것 — 이중으로 겹친다.)

의존성
  pip3 install pillow
"""

import argparse
import os
import sys

try:
    from PIL import Image, ImageFilter
except ImportError:
    sys.exit("Pillow가 필요합니다:  pip3 install pillow")

# Apple macOS App Icon 그리드 (1024 캔버스 기준)
CANVAS = 1024
BODY = 824                      # 본체 한 변
OPAQUE_THRESHOLD = 250          # 이 값 초과를 '본체'로 간주(그림자·안티에일리어싱 제외)

# Contents.json과 대응하는 산출물: (파일명, 픽셀 크기)
RENDITIONS = [
    ("icon_16x16@1x.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32@1x.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128@1x.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256@1x.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512@1x.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def body_bbox(image):
    """그림자와 안티에일리어싱을 제외한 본체 영역을 찾는다."""
    alpha = image.getchannel("A")
    opaque = alpha.point(lambda v: 255 if v > OPAQUE_THRESHOLD else 0)
    box = opaque.getbbox()
    if box is None:
        # 완전 불투명 영역이 없으면(전부 반투명 아트워크) 알파 전체로 대체
        box = alpha.getbbox()
    if box is None:
        sys.exit("아트워크를 찾을 수 없습니다. 알파 채널이 비어 있습니다.")
    return box


def build_master(source_path, with_shadow):
    """마스터를 그리드에 맞춰 1024 캔버스에 재배치한다."""
    source = Image.open(source_path).convert("RGBA")

    left, top, right, bottom = body_bbox(source)
    art = source.crop((left, top, right, bottom))
    width, height = art.size

    # 긴 변을 BODY에 맞춰 축소 — 어떤 축도 그리드를 넘지 않게 한다.
    scale = BODY / max(width, height)
    target = (max(1, round(width * scale)), max(1, round(height * scale)))
    art = art.resize(target, Image.LANCZOS)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = ((CANVAS - target[0]) // 2, (CANVAS - target[1]) // 2)

    if with_shadow:
        # Apple 기본 아이콘과 유사한 은은한 드롭섀도.
        # 본체 실루엣을 흐린 뒤 아래로 살짝 내려 깐다.
        silhouette = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        silhouette.paste(art, (offset[0], offset[1] + round(CANVAS * 0.010)), art)
        shadow_alpha = silhouette.getchannel("A").filter(
            ImageFilter.GaussianBlur(CANVAS * 0.012)
        )
        shadow_alpha = shadow_alpha.point(lambda v: int(v * 0.28))
        shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 255))
        shadow.putalpha(shadow_alpha)
        canvas = Image.alpha_composite(canvas, shadow)

    canvas.paste(art, offset, art)
    return canvas, (left, top, right, bottom), scale


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("master", help="원본 아이콘 PNG (1024x1024 이상 권장)")
    parser.add_argument(
        "--out",
        default="TriClean/Assets.xcassets/AppIcon.appiconset",
        help="출력 디렉터리 (기본: 프로젝트 아이콘셋)",
    )
    parser.add_argument(
        "--shadow", action="store_true", help="드롭섀도를 합성한다"
    )
    args = parser.parse_args()

    if not os.path.isfile(args.master):
        sys.exit(f"마스터 파일을 찾을 수 없습니다: {args.master}")

    source_size = Image.open(args.master).size
    if min(source_size) < CANVAS:
        print(
            f"⚠️  마스터가 {source_size[0]}x{source_size[1]}로 {CANVAS}px 미만입니다. "
            "확대 보간이 발생해 품질이 떨어집니다."
        )

    master, box, scale = build_master(args.master, args.shadow)

    body_w = box[2] - box[0]
    body_h = box[3] - box[1]
    print(f"마스터: {args.master} ({source_size[0]}x{source_size[1]})")
    print(f"  감지된 본체: {body_w}x{body_h}  (원본 점유율 {body_w / source_size[0] * 100:.1f}%)")
    print(f"  적용 배율: {scale:.4f}  →  그리드 점유율 {BODY / CANVAS * 100:.2f}%")
    print(f"  드롭섀도: {'합성' if args.shadow else '없음'}")
    print()

    os.makedirs(args.out, exist_ok=True)
    for filename, size in RENDITIONS:
        rendition = master if size == CANVAS else master.resize((size, size), Image.LANCZOS)
        path = os.path.join(args.out, filename)
        rendition.save(path, "PNG", optimize=True)
        print(f"  ✓ {filename:24} {size}x{size}")

    print(f"\n완료 — {args.out}")
    print("참고: Xcode 26+의 주 아이콘은 TriClean/AppIcon.icon입니다.")
    print("레거시 아이콘셋 확인 후 Product ▸ Clean Build Folder로 다시 빌드하세요.")
    print("Dock 아이콘 캐시가 남으면:  killall Dock")


if __name__ == "__main__":
    main()
