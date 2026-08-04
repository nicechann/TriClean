#!/usr/bin/env python3
"""
TriClean 로컬라이제이션 정합성 검사.

프로젝트 루트에서 실행:  python3 Scripts/verify_localizations.py

검사 항목
  1) 코드에서 참조하는 키가 각 언어에 존재하는지 (누락 시 영어로 폴백되지만 번역이 빠진 것)
  2) 언어별 포맷 지정자(%@, %ld …)가 기준 언어(en)와 일치하는지  ← 불일치는 런타임 크래시 위험
  3) .localized(with:)에 넘기는 인자 개수가 포맷 지정자 개수와 맞는지
  4) 중복 정의된 키
  5) 어느 언어에도 쓰이지 않는 키

키 참조는 `.localized` 부착 여부와 무관하게 모든 문자열 리터럴을 대조한다.
(변수·삼항으로 전달되는 키가 있으므로 — 예: LargeFilesView의 msg_folder/msg_file)
"""
import re, sys, glob, os
from collections import Counter

BASE = "en"
SRC_DIR = "TriClean"

def strings_files():
    return sorted(glob.glob(os.path.join(SRC_DIR, "*.lproj", "Localizable.strings")))

def lang_of(path):
    return os.path.basename(os.path.dirname(path)).replace(".lproj", "")

def parse(path):
    entries, dupes = {}, []
    for line in open(path, encoding="utf-8"):
        m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', line)
        if m:
            k, v = m.group(1), m.group(2)
            if k in entries:
                dupes.append(k)
            entries[k] = v
    return entries, dupes

SPEC = re.compile(
    r'%(\d+\$)?[-+ #0]*[\d*]*(?:\.\d+)?(?:hh|h|ll|l|L|z|j|t|q)?'
    r'([@dDuUxXoOfeEgGcCsSpaAn%])'
)

def specifiers(text):
    return [m.group(2) for m in SPEC.finditer(text) if m.group(2) != "%"]

def arg_count(text):
    ids, positional = set(), 0
    for m in SPEC.finditer(text):
        if m.group(2) == "%":
            continue
        if m.group(1):
            ids.add(int(m.group(1)[:-1]))
        else:
            positional += 1
    return max(len(ids), positional)

def split_args(text):
    depth, parts, cur, in_str = 0, [], "", False
    for ch in text:
        if ch == '"':
            in_str = not in_str
        if not in_str:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            elif ch == "," and depth == 0:
                parts.append(cur); cur = ""; continue
        cur += ch
    if cur.strip():
        parts.append(cur)
    return parts

def main():
    files = strings_files()
    if not files:
        print(f"오류: {SRC_DIR}/*.lproj/Localizable.strings 를 찾지 못했습니다.")
        return 1

    data, dupe_report = {}, {}
    for p in files:
        entries, dupes = parse(p)
        data[lang_of(p)] = entries
        if dupes:
            dupe_report[lang_of(p)] = dupes

    if BASE not in data:
        print(f"오류: 기준 언어 {BASE} 없음"); return 1

    langs = sorted(data)
    base = data[BASE]
    problems = 0

    # 소스에서 키 참조 수집 (모든 문자열 리터럴 대조)
    literals = set()
    swift = glob.glob(os.path.join(SRC_DIR, "**", "*.swift"), recursive=True)
    for f in swift:
        literals |= set(re.findall(r'"([^"\\\n]+)"', open(f, encoding="utf-8").read()))
    referenced = set(base) & literals

    print(f"언어 {len(langs)}개: {', '.join(langs)}")
    print(f"기준({BASE}) 키 {len(base)}개 · 소스에서 참조 {len(referenced)}개\n")

    # 1) 키 누락
    for l in langs:
        missing = sorted(referenced - set(data[l]))
        extra = sorted(set(data[l]) - set(base))
        status = f"  {l:8s} {len(data[l]):4d}키"
        if missing:
            status += f"  ❌ 누락 {len(missing)}"
            problems += 1
        else:
            status += "  ✅"
        if extra:
            status += f"  ⚠️ 기준에 없는 키 {len(extra)}"
        print(status)
        if missing:
            for k in missing[:10]:
                print(f"      누락: {k}")
            if len(missing) > 10:
                print(f"      … 외 {len(missing)-10}개")

    # 2) 포맷 지정자 불일치
    print()
    for l in langs:
        if l == BASE:
            continue
        for k, v in base.items():
            if k in data[l] and specifiers(v) != specifiers(data[l][k]):
                print(f"  ❌ 포맷 불일치 [{l}] {k}")
                print(f"       {BASE}: {v}")
                print(f"       {l}: {data[l][k]}")
                problems += 1

    # 3) 인자 개수
    pat = re.compile(r'"([a-zA-Z0-9_.]+)"\.localized\(with:\s*')
    for f in swift:
        src = open(f, encoding="utf-8").read()
        for m in pat.finditer(src):
            key = m.group(1)
            i, depth, in_str, buf = m.end(), 1, False, ""
            while i < len(src) and depth > 0:
                ch = src[i]
                if ch == '"':
                    in_str = not in_str
                if not in_str:
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                        if depth == 0:
                            break
                buf += ch; i += 1
            if key not in base:
                continue
            passed, want = len(split_args(buf)), arg_count(base[key])
            if passed != want:
                print(f"  ❌ 인자 개수 불일치 {os.path.basename(f)} [{key}] 전달 {passed} / 필요 {want}")
                problems += 1

    # 4) 중복 키
    for l, ks in dupe_report.items():
        print(f"  ❌ 중복 키 [{l}] {sorted(set(ks))}")
        problems += 1

    # 5) 미참조 키
    unused = sorted(set(base) - referenced)
    if unused:
        print(f"\n  ℹ️  어디서도 참조되지 않는 키 {len(unused)}개 (번역 불필요)")
        for k in unused[:5]:
            print(f"      {k}")
        if len(unused) > 5:
            print(f"      … 외 {len(unused)-5}개")

    print(f"\n{'❌ 문제 ' + str(problems) + '건' if problems else '✅ 문제 없음'}")
    return 1 if problems else 0

if __name__ == "__main__":
    sys.exit(main())
