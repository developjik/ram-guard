# RAM Guard

스왑데스(swap-death) 방어 맥 메뉴바 앱. 가용 메모리가 임계 이하로 떨어지면
같은 사용자의 가장 큰 RSS 프로세스를 SIGKILL로 즉시 종료해 시스템 전체
멈춤(수 시간 스왑 헬)을 막습니다. 검증된 `oom-watchdog.sh`의 Swift/AppKit 이식.

## 원리

- 가용 메모리 = `vm_stat`의 free + speculative 페이지 합계(`host_statistics64`)
- 10초 폴(전용 직렬 큐 + `DispatchSourceTimer`, 첫 틱 즉시 발화)
- 임계 이하 && 후보 존재 → 최대 RSS 후보 1개에 `kill(pid, SIGKILL)` 즉시 직행
- 킬 후 30초 쿨다운(연쇄 킬 방지), 후보 공집합 시 로그만
- 후보 조건(모두 만족): 같은 uid · RSS > 1,000,000 KiB(≈976.6 MiB) ·
  `/System` `/usr` `/bin` `/sbin` 경로 아님 · `kernel_task` 아님 · 자기 자신
  (pid/번들) 아님 · 제외 목록에 매칭 안 됨 · 경로 해석 가능
- 첫 실행은 **observe 전용**(킬 후보를 기록만). 메뉴에서 Armed로 전환하면
  실제 킬을 시작하고 이 상태는 재시작/재부팅 후에도 유지됩니다.

## 요구 사항

- Apple Silicon 맥 (arm64). 인텔 맥 미지원.
- macOS 13 Ventura 이상.

## 설치

1. [Releases](../../releases)에서 `RamGuard-<버전>-arm64.zip` 다운로드
2. 압축 해제 → `RamGuard.app`을 `/Applications`로 이동
3. **무서명(ad-hoc)·비공증 빌드입니다.** 첫 실행 차단 시:
   - 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기" (Sequoia 이상 현행 절차)
   - 우클릭 → 열기는 구버전 우회로로 레거시에서만 동작
   - 터미널 부록: `xattr -d com.apple.quarantine /Applications/RamGuard.app`
4. 실행하면 메뉴바에 방패 아이콘(회색 = observe)

## 첫 실행 가이드

1. 회색 방패(observe) 상태에서 평소처럼 작업
2. 메모리 압박 상황이 오면 메뉴의 이력에 `[would-kill]` 기록이 쌓임 —
   실제로 죽었을 프로세스를 미리 확인
3. 동작에 확신이 서면 메뉴에서 **"Armed로 전환"** (초록 방패). 이후 임계
   이하에서 실제 킬 시작
4. 임시 중단은 "Observe로 전환" 또는 앱 종료. 긴급 정지:
   `defaults write dev.ramguard.RamGuard ramguard.posture -string observe`

## 사용법

메뉴 구성(방패 아이콘 클릭):

- 가용 RAM 한 줄 (매 10초 갱신)
- Observe ↔ Armed 전환
- 임계치 서브메뉴: 프리셋(512~4096 MiB) ± 증감 버튼. 컨트롤 옆에 현재
  가용이 표시되고, 임계가 가용보다 크면 경고 표시(하드 제한 없음). 변경은
  다음 틱(최대 10초)에 즉시 반영되고 재시작 후 유지
- 킬 이력 (세션 단위, 최근 순)
- 제외 목록 파일 열기
- 로그인 시 자동 시작 토글
- 종료

아이콘: 회색 방패 = observe / 초록 방패 = armed / 빨강 방패 = 발동 직후

## 제외 목록

`~/.config/ramguard/exclusions.txt` — 한 줄에 프로세스 이름 하나.
`#`로 시작하는 줄은 주석. **대소문자 무시 부분 매칭**(예: `cursor`는
"Cursor Helper (GPU)"도 보호). 파일이 없으면 처음 실행 시 템플릿이 자동
생성됩니다. 변경은 **앱 재시작 후 적용**됩니다.

예:

```
# 에디터·세션 인프라 보호
Cursor
bun
node
ghostty
```

## v1 한계 (명시적)

1. **1GB 미만 다수 프로세스 합산 압박은 방어 못 함** — RSS 하한 1,000,000 KiB
   미만 프로세스는 후보가 아니므로, 여러 개가 쌓여 스왑데스를 유발하는
   상황은 잡지 못합니다 (v2 후보: 합산 기준).
2. **앱 크래시 중 무방어 공백** — 자동 재시작(KeepAlive)은 의도적으로
   넣지 않았습니다. 메뉴바 아이콘이 사라지면 앱이 죽은 것입니다.
3. **SIGKILL 즉시 종료로 미저장 데이터 손실 가능** — 희생 프로세스의
   저장 안 된 작업은 사라집니다. observe에서 먼저 확인하고 armed로
   전환하세요.
4. **인텔 맥 미지원.**

추가 알려진 동작: 임계 이하가 유지되는 동안 RSS가 커널에 압축된 프로세스는
실측 RSS가 줄어 후보에서 빠질 수 있습니다(측정은 `resident_size` 기준 —
원문 스크립트와 동일).

## 소스에서 빌드

```sh
swift build                      # 디버그
./scripts/make-app.sh            # Release → dist/RamGuard.app (ad-hoc 서명·검증)
./scripts/make-release.sh        # zip까지 (배포용)
.build/debug/RamGuard selftest   # 내장 단위 스위트 (75 checks)
.build/debug/RamGuard once       # vm_stat 패리티 측정 1회
./scripts/test/verify-vmstat.sh  # 측정 교차검증 (±5%)
```

macOS Command Line Tools만으로 빌드됩니다(Xcode 불필요).

## 라이선스

MIT — [LICENSE](LICENSE)
