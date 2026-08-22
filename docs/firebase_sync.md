# ESP AWS 백엔드 동기화

## 역할 분리

- 집중 세션과 감지 이벤트의 기준 저장소는 AWS 백엔드 뒤 PostgreSQL이다.
- ESP는 PostgreSQL에 직접 연결하지 않고 `wss://api.deskibot.co.kr/ws/focus`만 사용한다.
- HW 음성 서버의 Todo 조회·완료·삭제는 PostgreSQL만 사용한다.
- ESP의 기존 Todo 목록·마감 알림 폴링은 AWS REST 교체 전까지 임시 유지한다.
- 음성은 `POST https://api.deskibot.co.kr/hw/process`로 전송한다.

## 장치 인증

5인 테스트에서는 시리얼의 `token <값>` 명령으로 로봇별 device token을 NVS에
저장한다. 같은 NVS 토큰을 WSS 최초 인증의 `token`과 음성 API의
`X-Device-Key`에 사용하며 로그에는 값이나 일부 문자를 출력하지 않는다.

```json
{"type":"auth","token":"<device-token>","source":"robot"}
```

## 집중 세션

ESP의 시작 명령에는 로컬 세션 ID를 넣지 않는다. 서버가 브로드캐스트하는
`focus_state`에서 `session_id`와 `revision`을 저장하고, 이후 명령에 두 값을 넣는다.
서버의 상태 브로드캐스트는 앱과 로봇 UI가 동일한 상태를 보게 하는 기준이다.

```json
{"type":"focus_start","mode":"pomodoro","planned_duration_sec":1500}
{"type":"focus_start","mode":"stopwatch"}
{"type":"focus_pause","session_id":"<server-id>","revision":1}
{"type":"focus_resume","session_id":"<server-id>","revision":2}
{"type":"focus_end","session_id":"<server-id>","revision":3}
```

- 뽀모도로: 시작, 종료
- 스톱워치: 시작, 일시정지, 재개, 종료
- 이전 명령 이후 증가한 revision의 `focus_state`를 받기 전에는 다음 명령을 막는다.

## UART 감지 이벤트

RPi 입력은 `DROWSY:<0|1>,PHONE:<0|1>\n`이다. 각 값의 실제 전환에서만 이벤트를
전송한다. WSS가 끊겨 있으면 최신 상태를 보관했다가 재연결 후 전송한다.

```json
{"type":"detection_start","kind":"drowsy"}
{"type":"detection_end","kind":"drowsy"}
{"type":"detection_start","kind":"phone"}
{"type":"detection_end","kind":"phone"}
```

## 임시 Firestore ToDo 경로

`firebase_handler.h`의 Firestore REST 조회는 오늘의 미완료 ToDo와 마감 알림을 위해
유지한다. ToDo 서버 REST API가 준비되기 전에는 이 경로와 관련 secrets를 제거하지
않는다. 집중 세션 완료 기록은 Firestore로 보내지 않는다.
