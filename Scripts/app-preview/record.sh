#!/bin/zsh
# App Store 미리보기 영상(1920×1080, 30fps, H.264 + 무음 AAC)을 만든다.
#
# 사용법 (저장소 루트에서)
#   Scripts/app-preview/record.sh [언어] [로캘]     예) Scripts/app-preview/record.sh ko ko_KR
#
# 동작
#   1) Debug 빌드를 만든다(데모 모드는 DEBUG 빌드에만 들어 있다).
#   2) TRICLEAN_DEMO=1로 앱을 띄운다. 앱은 가상 데이터(/Users/demo 경로)로 화면을 채우고
#      정해진 순서로 넘기며, 표준 출력의 DEMO_* 줄로 녹화 타이밍을 알린다(TriClean/Shared/DemoMode.swift).
#   3) recorder가 TriClean 창 영역만 ScreenCaptureKit으로 캡처해 배경·자막과 합성한다.
#      다른 앱의 창은 캡처하지 않는다.
#   4) mux가 무음 스테레오 AAC 트랙을 더한다(App Preview는 오디오 트랙이 필요하다).
#
# 주의
#   - 실행한 터미널(또는 상위 앱)에 화면 기록 권한이 필요하다.
#   - 녹화 중(약 35초)에는 다른 창을 클릭하지 않는다. 창이 비활성 색으로 찍힌다.
#   - 창이 1400×850pt로 바뀌므로 화면의 보이는 영역이 그보다 커야 한다.
#   - 자막·"예시 데이터" 문구는 지정한 언어의 Localizable.strings(demo.*)를 따른다.
#     앱이 지원하지 않는 언어는 앱과 같은 기본 폴백 규칙을 쓴다.
set -eu

LANG_CODE=${1:-ko}
# 로캘을 생략하면 언어 코드를 그대로 써서 날짜·숫자 형식도 그 언어를 따르게 한다.
LOCALE=${2:-$LANG_CODE}
ROOT=${0:A:h:h:h}
OUT_DIR=$ROOT/build/app-preview
TOOLS=$OUT_DIR/tools
APP=$ROOT/build/demo/Build/Products/Debug/TriClean.app
mkdir -p $TOOLS

xcodebuild -project $ROOT/TriClean.xcodeproj -scheme TriClean -configuration Debug \
    -derivedDataPath $ROOT/build/demo build -quiet
swiftc -O $ROOT/Scripts/app-preview/recorder.swift -o $TOOLS/recorder
swiftc -O $ROOT/Scripts/app-preview/mux.swift -o $TOOLS/mux

RAW=$OUT_DIR/raw_$LANG_CODE.mov
FINAL=$OUT_DIR/TriClean_AppPreview_$LANG_CODE.mov
: > $OUT_DIR/app.out

# 녹화가 실패해도 app.out을 붙잡고 있는 tail이 남지 않게 한다.
# pkill 패턴은 정규식이라 "+"를 [+]로 감싼다.
cleanup() { pkill -f "tail -n [+]1 -f $OUT_DIR/app.out" || true }
trap cleanup EXIT

# Launch Services로 띄워야 앱이 앞으로 나와 활성 창으로 찍힌다.
open -n --env TRICLEAN_DEMO=1 --stdout $OUT_DIR/app.out --stderr $OUT_DIR/app.err $APP \
    --args -AppleLanguages "($LANG_CODE)" -AppleLocale $LOCALE
tail -n +1 -f $OUT_DIR/app.out | $TOOLS/recorder $RAW 2>$OUT_DIR/recorder.log &
RECORDER_PID=$!
RECORDER_STATUS=0
wait $RECORDER_PID || RECORDER_STATUS=$?
cat $OUT_DIR/recorder.log
if [[ $RECORDER_STATUS -ne 0 ]]; then
    echo "녹화 실패(종료 코드 $RECORDER_STATUS). $OUT_DIR/recorder.log와 app.err를 확인하세요." >&2
    exit $RECORDER_STATUS
fi

$TOOLS/mux $RAW $FINAL
echo "완료: $FINAL"
