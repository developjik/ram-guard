#!/bin/bash
# make-release.sh — build, bundle, sign, zip, verify the release artifact.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
ZIP="dist/RamGuard-v${VERSION}-arm64.zip"

./scripts/make-app.sh "$VERSION"

echo "==> zip"
( cd dist && ditto -c -k --keepParent RamGuard.app "RamGuard-v${VERSION}-arm64.zip" )

echo "==> release verification"
unzip -l "$ZIP" | grep -E "RamGuard.app/Contents/MacOS/RamGuard|Info.plist"
lipo -info dist/RamGuard.app/Contents/MacOS/RamGuard
codesign -dv dist/RamGuard.app 2>&1 | grep -E "Signature=adhoc"
echo "spctl (무서명이므로 거부가 정상):"
spctl -a -vv dist/RamGuard.app 2>&1 || true
echo "OK: $ZIP"

cat > dist/RELEASE_NOTES.md <<EOF
# RAM Guard v${VERSION}

스왑데스 방어 맥 메뉴바 앱 — Apple Silicon(macOS 13+) 전용.

## 설치
zip 해제 → RamGuard.app를 /Applications로 → Gatekeeper 안내는 README 참고
(무서명 ad-hoc 빌드: 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기").

## 핵심
- 가용 메모리(free+speculative) 임계 이하 시 최대 RSS 프로세스 SIGKILL 직행
- 첫 실행 observe 전용 → 메뉴에서 Armed 전환(상태 영속)
- 30초 킬 쿨다운·제외 목록(~/.config/ramguard/exclusions.txt)·킬 알림·이력
- 임계 기본 1200 MiB, 메뉴바에서 조절

## v1 한계
1GB 미만 다수 프로세스 합산 미방어 / 앱 크래시 중 공백(자동 재시작 없음) /
SIGKILL 즉시 종료로 미저장 데이터 손실 가능 / 인텔 미지원. 상세는 README.
EOF
echo "notes: dist/RELEASE_NOTES.md"
