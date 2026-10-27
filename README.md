# Token Meter

macOS 메뉴 막대에서 **로컬 Codex 세션 기록의 토큰 사용량**을 보여주는 SwiftUI 초안입니다.

```sh
cd "/Users/justcallmelight_/Documents/New project/token-meter"
swift run TokenMeter
```

앱은 `~/.codex/sessions/**/*.jsonl`의 `token_count` 이벤트를 읽기만 합니다. 입력·출력 토큰을 합산하고, 이벤트 발생 시각을 기준으로 오늘 사용량을 계산합니다. 캐시 입력은 입력 토큰의 일부이므로 총합에 다시 더하지 않습니다. 30초마다 자동 갱신되며 버튼으로 즉시 갱신할 수 있습니다.

이 수치는 이 Mac에 저장된 Codex 세션 기록에 한정됩니다. ChatGPT 전체 계정 사용량, 다른 기기의 사용량, API 청구 금액이나 계정 사용 한도를 뜻하지 않습니다. 기록이 삭제되거나 저장 형식이 바뀌면 표시값도 달라질 수 있습니다.
