# Token Meter

**언어 / Language:** [한국어](#한국어) · [English](#english)

## 한국어

macOS 메뉴 막대에서 **로컬 Codex 세션 기록의 토큰 사용량**을 보여주는 SwiftUI 개발 초기 앱입니다.

## 설치

1. [GitHub Releases](https://github.com/justcallmelightt/token-meter/releases)에서 `TokenMeter-*-macOS-universal.zip`을 내려받아 압축을 풉니다.
2. `Token Meter.app`을 응용 프로그램 폴더로 옮긴 뒤 실행합니다. Apple Silicon과 Intel Mac을 모두 지원하며 macOS 14 이상이 필요합니다.
3. 현재 배포 빌드는 Apple의 Developer ID 공증을 받지 않아 처음 실행할 때 macOS가 개발자를 확인할 수 없다는 경고를 표시할 수 있습니다. 이 경우 앱을 Control-클릭해 **열기**를 선택하고 한 번 더 확인합니다.
4. 메뉴 막대의 Token Meter 아이콘을 클릭하면 사용량을 볼 수 있습니다.

앱은 각 Mac의 `~/.codex/sessions/` 기록을 읽습니다. 기록이 없는 Mac에서는 토큰 수치가 표시되지 않습니다.

```sh
cd "/Users/justcallmelight_/Documents/New project/token-meter"
swift run TokenMeter
```

앱은 `~/.codex/sessions/**/*.jsonl`의 `token_count` 이벤트를 읽기만 합니다. 입력·출력 토큰을 합산하고, 이벤트 발생 시각을 기준으로 오늘 사용량을 계산합니다. 캐시 입력은 입력 토큰의 일부이므로 총합에 다시 더하지 않습니다. 첫 스캔에서는 각 세션의 최근 기록을 읽고, 이후에는 파일에 새로 추가된 부분만 읽습니다. 스캔 결과는 로컬 앱 설정에 저장되어 재실행 시 이전 수치를 즉시 표시합니다. 30초마다 자동 갱신되며 버튼으로 즉시 갱신할 수 있습니다.

메뉴 막대 창을 열면 마지막으로 화면에 표시했던 수치와 최신 수치를 비교합니다. 달라진 자릿수는 이전 값에서 최신 값으로 굴러가며, 앱을 종료했다가 다시 실행해도 마지막으로 본 수치를 기억합니다. 창이 열린 동안 새 기록이 들어와도 같은 방식으로 갱신합니다. 모션 줄이기 설정에서는 짧은 페이드로 표시합니다. 마지막으로 본 숫자와 스캔 캐시는 로컬 앱 설정에 저장하며 세션 기록 파일은 수정하지 않습니다.

이 수치는 이 Mac에 저장된 Codex 세션 기록에 한정됩니다. ChatGPT 전체 계정 사용량, 다른 기기의 사용량, API 청구 금액이나 계정 사용 한도를 뜻하지 않습니다. 기록이 삭제되거나 저장 형식이 바뀌면 표시값도 달라질 수 있습니다.

## 계정 한도와 설정

메뉴 막대 창의 설정(톱니바퀴)에서 Codex·Claude Code 한도 표시와 업데이트 확인을 관리할 수 있습니다.

- Codex 한도는 설치된 Codex CLI의 `app-server`를 통해 현재 로그인한 계정의 사용 창과 재설정 시각을 읽습니다. 계정이나 CLI 버전에서 한도 응답을 제공하지 않으면 표시되지 않을 수 있습니다.
- Claude Code 한도는 Claude Code 상태줄 입력에 포함된 5시간·주간 사용률과 재설정 시각을 사용합니다. 설정에서 **Claude Code 연결**을 선택하면 `~/.claude/settings.json`에 로컬 브리지를 연결합니다. 기존 상태줄 명령을 보존해 계속 실행하고, 연결 해제 시 이전 설정을 복원합니다. Claude Code 세션에서 데이터가 들어온 뒤 한도를 표시합니다.
- Token Meter는 6시간마다 GitHub의 최신 공개 릴리즈를 확인합니다. 업데이트가 있으면 다운로드 페이지를 열 수 있으며, 설치는 직접 진행해야 합니다.
- 패널 내용이 화면 높이보다 길면 패널 안에서 스크롤해 전체 항목을 확인할 수 있습니다.
- 한도 수치와 갱신 시각은 이 Mac의 앱 설정에 저장됩니다. Claude Code 브리지는 한도 퍼센트와 재설정 시각, 연결 해제 시 복원할 기존 상태줄 설정·명령을 앱 지원 폴더에 저장합니다. 이 파일은 현재 사용자만 읽고 쓸 수 있게 제한합니다.

## 개인정보 보호 및 보안

Token Meter는 로그인 없이 이 Mac에 저장된 Codex 세션 기록을 읽는 로컬 메뉴 막대 앱입니다.

- `~/.codex/sessions/**/*.jsonl`의 `token_count` 이벤트에서 입력·출력 토큰 수와 발생 시각을 계산합니다. 원본 기록 파일은 수정하거나 삭제하지 않습니다.
- 마지막으로 본 수치와 파일별 스캔 캐시는 macOS의 앱 설정(`UserDefaults`)에 저장됩니다. 캐시에는 기록 폴더 기준 상대 경로, 파일 크기·수정 시각, 읽은 위치와 토큰 합계가 포함됩니다. 대화 본문은 캐시에 저장하지 않습니다.
- 앱 설정은 암호화된 비밀 저장소가 아닙니다. 이 Mac의 사용자 계정과 Codex 기록 폴더에 대한 접근 권한을 관리해야 합니다.
- Token Meter는 세션 본문이나 인증 토큰을 외부로 보내지 않습니다. Codex 한도를 켜면 Codex CLI app-server가 기존 로그인 정보를 사용해 OpenAI에서 한도 정보를 조회합니다. Claude 한도는 Claude Code가 상태줄에 전달한 데이터를 로컬 브리지로 저장합니다.
- 업데이트 확인이 켜져 있으면 GitHub 공개 릴리즈 API에 버전 확인 요청을 보냅니다. Codex 세션 기록이나 계정 토큰은 요청에 포함하지 않습니다.
- 앱 설정을 삭제하면 저장된 수치와 캐시가 사라져 다음 실행 시 로컬 기록을 다시 읽습니다. Codex 원본 기록은 별도로 남습니다.
- 로컬 토큰 합계는 이 Mac에 남아 있는 기록만 반영합니다. 계정 한도는 Codex CLI app-server와 Claude Code 상태줄이 제공한 최신 값을 별도로 표시하며, 계정·플랜·버전에 따라 제공되지 않을 수 있습니다.

자세한 내용은 [개인정보 보호 및 보안](./SECURITY.md)을 참고하세요.

---

## English

Token Meter is an early-stage SwiftUI menu bar app for viewing token usage from local Codex session records on this Mac.

## Installation

1. Download `TokenMeter-*-macOS-universal.zip` from [GitHub Releases](https://github.com/justcallmelightt/token-meter/releases) and unzip it.
2. Move `Token Meter.app` to Applications and open it. The universal app supports Apple Silicon and Intel Macs running macOS 14 or later.
3. This build is not notarized with an Apple Developer ID, so macOS may show a security warning on first launch. If it does, Control-click the app, choose **Open**, and confirm.
4. Click the Token Meter icon in the menu bar to view usage.

The app reads records from each Mac's `~/.codex/sessions/`. It shows no token counts on a Mac without local Codex session records.

To run from source:

```sh
cd "/Users/justcallmelight_/Documents/New project/token-meter"
swift run TokenMeter
```

The app reads `token_count` events from `~/.codex/sessions/**/*.jsonl` and sums input and output tokens by event time. Cached input is already part of input totals and is not added again. The first scan reads recent records from each session; later scans read only appended data. Scan results are cached in local app preferences, refreshed every 30 seconds, and can be refreshed manually.

When the menu bar panel opens, Token Meter compares the last displayed value with the latest value and rolls changed digits to the new count. This also works after quitting and reopening the app, and while the panel remains open. Reduce Motion switches the rolling animation to a short fade. The app stores the last viewed count and scan cache locally and does not modify Codex session files.

These numbers only reflect Codex session records stored on this Mac. They do not represent total ChatGPT account usage, usage on other devices, API charges, or account limits. Values can change if records are deleted or their format changes.

## Account limits and settings

Use the gear button in the menu bar panel to control Codex and Claude Code limits and update checks.

- Codex limits come from the signed-in account through the installed Codex CLI `app-server`, including usage windows and reset times. A limit may be unavailable for some accounts or CLI versions.
- Claude Code limits use the five-hour and weekly percentages and reset times in Claude Code status line input. Selecting **Connect Claude Code** in Settings adds a local bridge to `~/.claude/settings.json`. The bridge preserves and continues running an existing status line command, then restores the previous setting when disconnected. Limits appear after Claude Code sends status line data from a session.
- Token Meter checks GitHub's latest published release every six hours. If a newer version is available, you can open its download page and install it manually.
- If the panel is taller than the available screen space, scroll inside it to reach all items.
- Limit values and update times are stored in this Mac's app preferences. The Claude Code bridge stores limit percentages and reset times, plus the previous status line configuration and command needed for restoration, in the app support folder with user-only file permissions.

## Privacy and Security

Token Meter reads local Codex session records on this Mac without requiring a login.

- It calculates input and output token counts and event timestamps from `token_count` events in `~/.codex/sessions/**/*.jsonl`. It does not modify or delete the original records.
- The last viewed count and per-file scan cache are stored in macOS app preferences (`UserDefaults`). The cache includes relative paths, file sizes and modification times, read offsets, and token totals; it does not store conversation bodies.
- App preferences are not an encrypted secret store. Protect access to this Mac user account and the Codex records folder.
- Token Meter does not send session transcripts or authentication tokens to external services. When Codex limits are enabled, Codex CLI app-server uses the existing sign-in to fetch limit information from OpenAI. Claude limits are saved locally from data Claude Code passes to its status line.
- When update checks are enabled, the app requests version information from GitHub's public releases API. It does not include Codex session records or account tokens in that request.
- Deleting app preferences removes the saved count and cache, so the app scans local records again the next time it runs. Original Codex records remain separate.
- Local token totals only reflect records still present on this Mac. Account limits are separate values supplied by Codex CLI app-server or Claude Code status line and may be unavailable for some accounts, plans, or versions.

See [Privacy and Security](./SECURITY.md) for details.
