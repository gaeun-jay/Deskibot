# Deskibot ESP–AWS–PostgreSQL 마이그레이션 인수인계

기준 시점: 2026-08-10  
로컬 프로젝트: [esp](/Users/gaeun/Documents/PlatformIO/Projects/esp)  
현재 변경사항은 대부분 커밋되지 않은 작업 트리에 있습니다. **`git reset`, `git checkout --`, 전체 파일 덮어쓰기 금지**입니다.

실제 device token, Firebase 키, DB 비밀번호 등 비밀값은 아래에 포함하지 않았습니다.

---

## 1. 최종 목표 구조

### ESP32-S3

- Wi‑Fi로 AWS 백엔드 접속
- 집중모드와 감지 이벤트는 WSS 사용
- 음성은 HTTPS `/hw/process` 사용
- 사용자 전환은 시리얼에서 device token 교체
- PostgreSQL에는 절대 직접 접속하지 않음

### AWS

- REST/WS 도메인: `https://api.deskibot.co.kr`
- 집중 WebSocket: `wss://api.deskibot.co.kr/ws/focus`
- 음성 API: `POST https://api.deskibot.co.kr/hw/process`
- WSS 서버 systemd: `deskibot-sw.service`
- 음성 서버 systemd: `deskibot-hw.service`
- EC2 음성 서버 경로: `/home/ubuntu/Deskibot/server/hw`

### 인증

- 각 로봇에 개별 device token 발급
- 서버는 받은 token을 SHA-256으로 해시
- PostgreSQL `devices.token_hash`와 비교
- 연결된 `devices.user_id`를 인증 사용자로 사용
- 평문 token은 PostgreSQL에 저장하지 않음
- ESP 로그에도 token 값이나 앞뒤 일부 문자를 출력하지 않음

### 데이터 기준 저장소

- 집중 세션: PostgreSQL
- 집중 이벤트: PostgreSQL
- 감지 이벤트: PostgreSQL
- 음성 Todo 조회/완료/삭제: PostgreSQL
- 기존 ESP의 Firestore Todo 폴링 및 마감 알림은 AWS Todo REST API가 준비될 때까지만 임시 유지

---

# 2. 지금까지 진행한 과정

## 2.1 기존 Firebase 역할 분석

Firebase 사용을 다음 두 영역으로 분리했다.

1. Firebase RTDB 집중모드 동기화
2. Firestore Todo 조회와 마감 알림

결론:

- 집중모드 동기화는 AWS WSS로 이전
- Firestore Todo는 대체 REST API가 없으므로 일단 유지
- Firebase를 한 번에 전부 지우면 안 됨

특히 현재 `Firebase_ESP_Client` 라이브러리는 Firestore뿐 아니라 `FirebaseJson` 파서로도 사용된다. 따라서 Firestore를 나중에 제거하더라도 `aws_backend.h` 등의 JSON 파서를 먼저 다른 라이브러리로 교체하지 않으면 Firebase 라이브러리를 삭제할 수 없다.

관련 문서: [firebase_sync.md](/Users/gaeun/Documents/PlatformIO/Projects/esp/docs/firebase_sync.md)

---

## 2.2 AWS WSS 집중모드 구현

신규 파일: [aws_backend.h](/Users/gaeun/Documents/PlatformIO/Projects/esp/src/aws_backend.h)

구현된 기능:

- `wss://api.deskibot.co.kr/ws/focus` TLS 연결
- 최초 연결 후 인증 메시지 전송

```json
{"type":"auth","token":"<device-token>","source":"robot"}
```

- 자동 재연결
- heartbeat
- `auth_ok` 또는 `authenticated` 처리
- `focus_state` 수신
- 서버가 반환한 `session_id`, `revision` 저장
- 명령 전송 후 더 높은 revision의 상태를 받을 때까지 후속 명령 차단
- 서버 상태를 LVGL 뽀모도로/스톱워치 화면에 반영
- 토큰 누락 시 명령 전송 차단

집중 명령:

```json
{"type":"focus_start","mode":"pomodoro","planned_duration_sec":1500}
{"type":"focus_start","mode":"stopwatch"}
{"type":"focus_pause","session_id":"...","revision":0}
{"type":"focus_resume","session_id":"...","revision":1}
{"type":"focus_end","session_id":"...","revision":2}
```

지원 범위:

- 뽀모도로: 시작, 종료
- 스톱워치: 시작, 일시정지, 재개, 종료

---

## 2.3 device token NVS 저장 및 사용자 교체

5인 테스트에서는 6자리 페어링을 사용하지 않고 사용자별 사전 발급 token을 사용하도록 변경했다.

시리얼 명령:

```text
token <실제_device_token>
```

동작:

1. token 형식 검사
2. ESP NVS의 `deskibot/token`에 저장
3. 런타임 token 교체
4. 기존 WSS 연결 종료
5. 새 token으로 자동 재인증
6. 음성 Todo pending context 초기화
7. 재부팅 후에도 token 유지

보안 처리:

- token 자체는 로그에 출력하지 않음
- 길이만 출력
- 빈 token 거부
- 최대 127자
- 공백 및 제어문자 포함 token 거부
- 알 수 없는 시리얼 명령도 원문을 출력하지 않음

예상 로그:

```text
[Token] 저장됨 (len=...) — WS 재연결
[AWS WS] 연결됨
[AWS WS] 인증 메시지 전송
[AWS WS] 인증 완료
```

현재 실제 장치에서 `인증 완료`까지 확인됐다. 처음에는 잘못된 token을 ESP에 입력해서 서버가 연결을 끊었지만, 올바른 token을 다시 넣은 뒤 해결됐다.

---

## 2.4 UART 감지 이벤트 구현

신규 파일: [uart_rpi.h](/Users/gaeun/Documents/PlatformIO/Projects/esp/src/uart_rpi.h)

프로토콜:

```text
DROWSY:<0|1>,PHONE:<0|1>\n
```

예:

```text
DROWSY:1,PHONE:0
```

동작:

- `DROWSY`가 `0→1`: `detection_start/drowsy`
- `DROWSY`가 `1→0`: `detection_end/drowsy`
- `PHONE`이 `0→1`: `detection_start/phone`
- `PHONE`이 `1→0`: `detection_end/phone`
- 값이 바뀌지 않으면 중복 전송하지 않음
- WSS가 끊기면 최신 상태를 dirty 상태로 보존
- 재연결 후 다시 전송 시도
- 기존 졸음/폰 팝업과 경고음도 함께 작동
- UART 링크 상태를 `[Diag]`에 표시
- `PING\n`을 받으면 `PONG\n` 응답

핀:

- ESP RX: GPIO18
- ESP TX: GPIO17
- baud: 115200

RPi 배선:

- RPi GPIO14/TX → ESP GPIO18/RX
- RPi GPIO15/RX ← ESP GPIO17/TX
- GND 공통 연결 필수

UART 자체는 과거에 실제 통신 테스트를 완료했다고 사용자가 확인했다. 현재 RPi가 없어서 UART → AWS 감지 이벤트 전체 E2E 테스트는 아직 하지 못했다.

---

## 2.5 음성 API를 AWS HTTPS로 변경

파일: [voice.h](/Users/gaeun/Documents/PlatformIO/Projects/esp/src/screens/voice.h)

변경된 URL:

```text
POST https://api.deskibot.co.kr/hw/process
```

헤더:

```text
Content-Type: application/octet-stream
X-Device-Key: <NVS device token>
```

핵심 변경:

- 기존 공용 `DEVICE_API_KEY` 제거
- `aws_backend.h`의 `aws_get_device_token()`을 사용
- WSS와 음성 API가 동일한 NVS token을 사용
- token이 없으면 음성 요청 취소
- 실제 CA 인증서를 사용
- `setInsecure()`를 사용하지 않음
- 실제 token은 로그에 출력하지 않음

응답 바이너리 구조:

```text
[4바이트 STT 문자열 길이]
[STT UTF-8]
[4바이트 command JSON 길이]
[command JSON UTF-8]
[16-bit mono 16kHz PCM]
```

ESP는 응답을 파싱한 뒤 TTS PCM을 재생한다.

아직 실제 장치에서 `/hw/process`의 정상 200 응답과 음성 재생까지는 확인하지 못했다.

---

# 3. AWS 음성 서버 로컬 구현

주요 파일:

- [server.py](/Users/gaeun/Documents/PlatformIO/Projects/esp/server/server.py)
- [todo_matching.py](/Users/gaeun/Documents/PlatformIO/Projects/esp/server/todo_matching.py)
- [register_test_device.py](/Users/gaeun/Documents/PlatformIO/Projects/esp/server/register_test_device.py)
- [EC2_DEPLOY_HW_AUTH.md](/Users/gaeun/Documents/PlatformIO/Projects/esp/server/EC2_DEPLOY_HW_AUTH.md)

## 3.1 `/hw/process` device token 인증

구현 내용:

1. `X-Device-Key` 읽기
2. 빈 token 또는 127자 초과 거부
3. SHA-256 해시 계산
4. PostgreSQL `devices.token_hash` 검색
5. 일치하는 device의 `user_id` 반환
6. `devices.last_seen_at` 갱신
7. 인증 실패 시 HTTP 401
8. DB 오류 시 HTTP 503
9. 로그에 token/hash를 출력하지 않음

공용 `DEVICE_API_KEY`는 새 로컬 코드에서 사용하지 않는다.

---

## 3.2 인증된 사용자와 Todo 연결

음성 Todo SQL에는 항상 인증된 `user_id`가 포함된다.

지원 기능:

- 오늘 미완료 Todo 조회
- Todo 완료 처리
- Todo 삭제
- 다른 사용자의 Todo 접근 방지
- exact match 우선
- 유일한 포함 일치만 허용
- 후보가 여러 개면 변경하지 않음
- 후보가 없으면 변경하지 않음
- 한 음성 요청에서 변경 작업은 최대 하나

오늘 Todo 조회:

- `Asia/Seoul` 날짜 기준
- `is_done = false`
- deadline 순으로 정렬
- 음성으로 최대 4개 안내
- 나머지가 있으면 “그 외 N개”로 요약

현재 서버는 Todo 추가 및 수정은 지원하지 않으며, 요청하면 지원하지 않는다고 안내하도록 Claude 프롬프트에 명시돼 있다.

---

## 3.3 Todo 후보 선택 테스트

로컬에서 다음 검증을 완료했다.

```bash
cd /Users/gaeun/Documents/PlatformIO/Projects/esp/server
python3 -m py_compile server.py todo_matching.py register_test_device.py seed_test_fixtures.py
python3 -m unittest -v test_todo_matching.py
```

결과:

```text
Ran 7 tests
OK
```

테스트 항목:

- 빈 힌트 거부
- 후보 없음 처리
- 정확 일치
- 중복 정확 일치 거부
- 유일한 포함 일치
- 복수 포함 후보 거부
- 대소문자 및 공백 정규화

주의: unittest는 반드시 `server` 디렉터리에서 실행해야 `todo_matching` import가 정상 작동한다.

---

# 4. 테스트 계정과 fixture

사용자를 두 유형으로 나눴다.

- 학생 테스트 계정
- 직장인 테스트 계정

EC2에서 fixture dry-run과 실제 적용을 완료했다.

실제 적용 결과:

```text
analysis_cumulative=4
analysis_daily=4
categories=6
devices=2
focus_events=6
focus_sessions=6
stats_daily=4
stats_timeslots=8
todos=14
users=2
worker_token_created=False
```

포함된 데이터 유형:

- 학생/직장인 각각의 카테고리
- 오늘 Todo
- 완료된 Todo
- 지난 날짜 Todo
- 다음 날짜 Todo
- deadline 있음/없음
- 알림 있음/없음
- 뽀모도로 완료/미완료
- 스톱워치 완료
- pause 이벤트
- 일별/누적 분석
- 시간대별 통계

`worker_token_created=False`의 의미:

- worker device가 이미 존재했기 때문에 seed 스크립트가 token hash를 덮어쓰지 않았음
- 다만 이번 인증 장애의 실제 원인은 ESP에 token을 잘못 입력한 것이었음
- 올바른 token으로 ESP가 현재 WSS 인증에 성공했으므로 해당 DB device token은 유효함

---

# 5. UI 디자인 변경

## 5.1 팝업

파일:

- [popup.h](/Users/gaeun/Documents/PlatformIO/Projects/esp/src/screens/popup.h)
- [popup_drowsy_bg.c](/Users/gaeun/Documents/PlatformIO/Projects/esp/backgrounds/popup_drowsy_bg.c)
- [popup_phone_bg.c](/Users/gaeun/Documents/PlatformIO/Projects/esp/backgrounds/popup_phone_bg.c)
- [popup_deadline_bg.c](/Users/gaeun/Documents/PlatformIO/Projects/esp/backgrounds/popup_deadline_bg.c)

구조:

- 팝업의 원형 배경과 아이콘: 이미지
- 안내 문구: LVGL label
- 확인 버튼: LVGL button
- Todo 제목/시간/남은 시간: LVGL label
- 바깥 영역: 단색 `0x0A121E`
- 팝업 이미지 내부의 디자인은 제공된 이미지 유지

현재 문구:

졸음:

```text
Deskibot이 졸음을 감지했어요
잠깐 물 한 잔 마셔보는 것이 어떨까요?
```

스마트폰:

```text
Deskibot이 스마트폰 사용을 감지했어요
다시 책상으로 돌아가, 집중해볼까요?
```

확인 버튼 글리프가 네모로 깨지는 문제를 해결하기 위해 `pretendard_regular_28` 폰트에 필요한 한글 글리프를 포함시켰다.

스마트폰 문구의 `책상으로 돌아가` 글리프도 폰트 자산에 반영했다.

시리얼 UI 테스트 명령:

```text
popup drowsy
popup phone
popup deadline
```

커스텀 deadline:

```text
deadline 09:00 PM 알고리즘 과제 30분
```

팝업 색상은 제공받은 원본 디자인 이미지로 다시 구성했지만, 최종 실제 LCD 색상과 경계선에 대한 사용자 승인까지 명시적으로 완료되지는 않았다. 한 번 더 실제 장치 시각 검수가 필요하다.

---

## 5.2 뽀모도로

파일:

- [pomodoro.h](/Users/gaeun/Documents/PlatformIO/Projects/esp/src/screens/pomodoro.h)
- [tomato.c](/Users/gaeun/Documents/PlatformIO/Projects/esp/assets/tomato.c)
- [bg_pomodoro_start.c](/Users/gaeun/Documents/PlatformIO/Projects/esp/backgrounds/bg_pomodoro_start.c)
- [bg_pomodoro_end.c](/Users/gaeun/Documents/PlatformIO/Projects/esp/backgrounds/bg_pomodoro_end.c)

반영 내용:

- 토마토를 위쪽으로 이동
- 토마토 floating animation 유지
- 25분/50분 버튼 색을 동일하게 통일
- 버튼 너비를 126px로 축소
- 버튼 높이 64px
- 완전한 capsule radius 적용
- 시작/실행 배경 이미지 추가
- 완료 화면을 제공받은 DONE/토마토/체크 디자인 이미지로 변경
- 완료 화면은 3초 후 초기 화면 복귀

현재 완료 화면의 “완료!” 텍스트는 배경 이미지에 포함돼 있어 별도 LVGL 완료 label은 숨긴다.

---

## 5.3 음성 화면

파일 및 자산:

- [voice.h](/Users/gaeun/Documents/PlatformIO/Projects/esp/src/screens/voice.h)
- [character_voice.c](/Users/gaeun/Documents/PlatformIO/Projects/esp/backgrounds/character_voice.c)
- [btn_mic.c](/Users/gaeun/Documents/PlatformIO/Projects/esp/backgrounds/btn_mic.c)
- [voice_wave_dot.c](/Users/gaeun/Documents/PlatformIO/Projects/esp/backgrounds/voice_wave_dot.c)

반영 내용:

- 캐릭터 확대
- 안내 문구 확대
- 안내 문구를 캐릭터 위에 배치
- 마이크 버튼 크기/위치 조정
- 녹음 및 처리 중 마젠타 버튼 제거
- 파란 원 4개가 순차적으로 위아래로 움직이는 wave animation 추가
- 녹음 중 원 영역을 누르면 녹음 종료 가능
- 서버 처리 및 TTS 재생 중에도 wave 표시

대기 문구:

```text
데스키봇에게
요청해 보세요
```

녹음 문구:

```text
사용자님의 음성을
인식하고 있어요
```

---

# 6. 현재 실제 장치 테스트 결과

## 6.1 확인 완료

실제 로그:

```text
[AWS WS] 연결됨
[AWS WS] 인증 메시지 전송
[AWS WS] 인증 완료
```

따라서 다음은 정상이다.

- Wi‑Fi
- DNS
- TLS 인증서
- WSS handshake
- device token
- PostgreSQL `devices.token_hash` 인증
- 서버의 auth 응답
- WSS 연결 유지

---

## 6.2 집중 시작 명령 전송 확인

실제 로그:

```text
[AWS WS] focus_start 전송
[Pomo] 25분 시작 요청
```

따라서 ESP의 버튼 이벤트와 WebSocket 송신까지는 정상이다.

하지만 당시 서버 응답 파싱에 실패했다.

```text
[AWS WS] focus_state 필수 필드 누락
```

그 결과:

- `session_id` 저장 실패
- `revision` 저장 실패
- `_focus_command_pending`이 계속 true
- 종료 버튼에서 다음 로그 발생

```text
[AWS WS] 이전 집중 명령의 focus_state 대기 중
[Pomo] 강제 종료
```

중요한 의미:

- 화면은 로컬에서 완료 상태로 바뀌었지만
- 실제 `focus_end`는 서버로 전송되지 않았음
- PostgreSQL에는 이전 25분 세션이 여전히 진행 상태로 남았을 가능성이 있음

---

# 7. 가장 최근 적용한 수정

[aws_backend.h](/Users/gaeun/Documents/PlatformIO/Projects/esp/src/aws_backend.h)의 `focus_state` 파서를 확장했다.

기존 누락:

- `session/session_id`
- `session/status`
- `focus/id`
- `focus/status`
- 기타 중첩 응답

추가 지원 형태:

- flat
- `focus/{...}`
- `session/{...}`
- `data/{...}`
- `data/session/{...}`
- `active_session/{...}`

지원 필드 별칭:

- ID: `session_id`, `id`
- 상태: `state`, `status`
- mode
- revision
- planned duration
- total pause
- started time
- paused time

파싱 실패 로그도 실제 값을 출력하지 않고 다음과 같이 변경했다.

```text
[AWS WS] focus_state 필드 상태: session_id=ok mode=missing state=ok revision=ok
```

이 수정은 PlatformIO 빌드에 성공했지만, **아직 사용자가 새 펌웨어를 업로드해 실제 서버 응답으로 재검증하지 않았다.**

---

# 8. 마지막 PlatformIO 빌드 결과

실행:

```bash
cd /Users/gaeun/Documents/PlatformIO/Projects/esp
pio run
```

결과:

```text
SUCCESS
```

세부 결과:

- RAM: 140,396 / 327,680 bytes, 42.8%
- Flash: 6,284,939 / 6,553,600 bytes, 95.9%
- 전체 이미지: 약 6.285MB

주의:

- Flash 여유가 약 4.1%뿐이다.
- 새로운 대형 이미지를 추가할 때 파티션 한도를 넘을 위험이 크다.
- 미사용 이미지/폰트 정리 또는 파티션 재검토가 필요할 수 있다.
- `XPOWERS_CHIP_AXP2101` 재정의 warning이 있지만 빌드는 성공한다.
- linker의 GNU-stack warning도 있지만 현재 빌드 실패 원인은 아니다.

---

# 9. 현재 해결되지 않은 메모리 문제

실제 로그:

```text
esp-aes: Failed to allocate memory
ssl_starttls_handshake(): ERROR - Generic error
NetworkClientSecure connect failed
[Fetch] HTTP -1
```

당시 heap:

```text
heap 약 28~30KB
```

원인:

- WSS TLS 연결이 이미 유지 중
- 음성 화면 진입 시 Firestore HTTPS 조회 task 생성
- Firestore TLS handshake가 추가 내부 heap을 요청
- 가용 연속 메모리가 부족해 AES/TLS 할당 실패

현재 `firebase_fetch_tasks()`는 10,240바이트 task stack을 새로 만들고, 별도의 `WiFiClientSecure`를 생성한다.

이 문제는 WSS 집중모드 자체의 문제가 아니라 **WSS와 기존 Firestore HTTPS의 동시 TLS 메모리 경쟁**이다.

현재 Firestore 요청은 별도로 HTTP 403도 반환했다.

```text
[Fetch] HTTP 403
```

즉 기존 Firestore 폴링은 현재:

- 인증/규칙 문제로 기능하지 않고
- 동시에 ESP TLS 메모리를 압박하고 있음

---

# 10. Firestore 관련 중요한 구조적 문제

[firebase_handler.h](/Users/gaeun/Documents/PlatformIO/Projects/esp/src/firebase_handler.h)는 아직 다음 기능을 담당한다.

- 오늘 미완료 Todo 조회
- 마감 알림 대상 캐시
- deadline popup
- 졸음/폰 상태 변화와 팝업 연결

Firestore URL은 컴파일 상수인 `FS_USER_ID`를 사용한다.

문제:

- NVS device token으로 사용자를 변경해도 `FS_USER_ID`는 바뀌지 않음
- 따라서 Firestore 403을 해결하더라도 학생/직장인 token 전환과 로컬 Todo 사용자가 일치하지 않을 수 있음
- 5인 테스트에서 다른 사용자의 Todo/마감 알림을 표시할 위험이 있음

따라서 최종적으로 필요한 것은:

1. AWS 사용자 인증 기반 Todo REST API 구현
2. ESP의 Firestore 조회를 해당 REST API로 교체
3. 마감 알림 데이터도 인증된 사용자 기준으로 가져오기
4. 이후 Firestore 상수 및 관련 코드 제거
5. `FirebaseJson` 사용처를 다른 JSON 파서로 교체
6. 마지막에 `Firebase_ESP_Client` 의존성 제거

현재 단계에서 Firestore 코드를 그냥 삭제하면 deadline 기능이 사라지고, `FirebaseJson` 때문에 빌드도 깨질 수 있다.

---

# 11. AWS 음성 서버 EC2 상태

확실하게 완료된 것:

- PostgreSQL fixture는 EC2에서 적용됨
- WSS 인증은 실제 장치에서 성공
- WSS용 DB device token이 유효함

확인이 필요한 것:

- 로컬의 새 [server.py](/Users/gaeun/Documents/PlatformIO/Projects/esp/server/server.py)가 `deskibot-hw.service`에 실제로 배포돼 있는지
- EC2 `/hw/process`가 아직 공용 `DEVICE_API_KEY` 버전인지, PostgreSQL token 버전인지
- 정상 token + 빈 body 요청이 400을 반환하는지
- 실제 PCM 요청이 200을 반환하는지
- 인증된 사용자별 Todo 격리가 되는지

배포 절차는 [EC2_DEPLOY_HW_AUTH.md](/Users/gaeun/Documents/PlatformIO/Projects/esp/server/EC2_DEPLOY_HW_AUTH.md)에 정리돼 있다.

검증 명령:

```bash
curl -fsS https://api.deskibot.co.kr/hw/health
```

예상:

```text
ok
```

token 없음:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST https://api.deskibot.co.kr/hw/process
```

예상:

```text
401
```

잘못된 token:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST \
  -H 'X-Device-Key: invalid-test-token' \
  https://api.deskibot.co.kr/hw/process
```

예상:

```text
401
```

실제 token은 명령행이나 채팅에 직접 쓰지 말고 숨김 입력 또는 안전한 환경변수로 처리해야 한다.

---

# 12. 다음 AI가 가장 먼저 해야 할 일

## 1단계: 최신 ESP 펌웨어 업로드

현재 `focus_state` 확장 파서가 빌드만 되고 실제 장치에는 아직 올라가지 않았다.

```bash
cd /Users/gaeun/Documents/PlatformIO/Projects/esp
pio run -t upload
pio device monitor -b 115200
```

---

## 2단계: 인증 직후 snapshot 확인

예상:

```text
[AWS WS] 인증 완료
[AWS WS] focus_state mode=pomodoro state=running revision=...
```

이전에 종료하지 못한 25분 세션이 서버에 남아 있다면 재접속 snapshot으로 복원될 수 있다.

복원되면 종료 버튼을 눌러 다음을 확인한다.

```text
[AWS WS] focus_end 전송
[AWS WS] focus_state mode=pomodoro state=completed revision=...
```

---

## 3단계: 확장 파서가 여전히 실패하는 경우

새 로그는 누락 필드를 알려준다.

예:

```text
[AWS WS] focus_state 필드 상태: session_id=missing mode=ok state=ok revision=ok
```

이때 해야 할 일:

1. `deskibot-sw.service`가 보내는 실제 `focus_state` JSON 구조 확인
2. token은 절대 출력하지 않기
3. 필요한 경우 session ID 값도 가리고 구조만 확인
4. ESP 파서 또는 서버 payload를 하나의 공식 schema로 통일
5. 임의의 별칭을 계속 추가하기보다 서버 contract를 확정하는 것이 바람직함

서버 로그:

```bash
sudo journalctl -u deskibot-sw.service -n 100 --no-pager
```

실시간:

```bash
sudo journalctl -u deskibot-sw.service -f
```

---

## 4단계: 집중모드 전체 테스트

### 뽀모도로

- 25분 시작
- 강제 종료
- 50분 시작
- 강제 종료
- 자연 완료는 실제 25분을 기다리거나 테스트 빌드에서 짧은 시간으로 검증
- PostgreSQL 상태 확인
- 재부팅 후 active session 복원 확인
- 네트워크 재연결 후 session/revision 복원 확인

### 스톱워치

- 시작
- 일시정지
- 재개
- 종료
- pause 누적 시간 확인
- revision이 매 단계 증가하는지 확인
- 같은 revision 재전송 시 서버가 충돌을 거부하는지 확인
- 앱이 없어도 로봇 단독 흐름은 검증 가능

---

## 5단계: Firestore TLS 메모리 문제 처리

단기 해결안:

- free heap/최대 연속 heap이 부족하면 Firestore fetch를 시작하지 않기
- HTTP 401/403 이후 매분 재시도하지 않고 해당 부팅 동안 비활성화
- 음성 녹음/처리/WSS 명령 대기 중 Firestore fetch 금지
- Firestore task stack 크기와 할당 위치 검토
- WSS 연결을 끊는 방식은 집중 동기화를 깨므로 가급적 피하기

권장 최종 해결안:

- AWS Todo REST endpoint 구현
- 동일한 `X-Device-Key` 인증 사용
- 작은 JSON 응답으로 오늘 Todo와 deadline만 전달
- ESP에서 기존 Firestore HTTPS 호출을 AWS REST로 교체
- Firestore 제거

---

## 6단계: 음성 전체 E2E 테스트

확인 순서:

1. `/hw/health`
2. token 없음 → 401
3. 잘못된 token → 401
4. 정상 token + 빈 body → 400
5. ESP 음성 녹음
6. `/hw/process` 200
7. STT 문자열 수신
8. command JSON 파싱
9. TTS PCM 수신
10. 스피커 재생
11. 학생 token으로 학생 Todo 조회
12. 직장인 token으로 직장인 Todo 조회
13. 완료 처리
14. 삭제 처리
15. 모호한 항목은 변경되지 않는지 확인
16. 다른 사용자의 Todo가 절대 변경되지 않는지 DB 확인

---

## 7단계: UART 감지 E2E

RPi가 준비되면:

```text
DROWSY:0,PHONE:0
DROWSY:1,PHONE:0
DROWSY:1,PHONE:1
DROWSY:0,PHONE:1
DROWSY:0,PHONE:0
```

검증:

- 실제 변화에서만 WS 이벤트 전송
- 동일한 줄 반복 시 중복 이벤트 없음
- 졸음/폰 popup 표시
- detection_end에서 popup/경고음 종료
- PostgreSQL 감지 이벤트 저장
- WSS 끊김 중 상태 변경 후 재연결 전송
- `PING/PONG` UART 왕복

---

# 13. 남은 작업량 추정

외부 환경과 서버 payload에 따라 달라지지만 현실적으로 다음 정도다.

| 작업 | 상태 | 예상 |
|---|---|---:|
| 최신 focus parser 업로드 및 확인 | 빌드 완료, 실기기 미검증 | 30분~2시간 |
| 남은 active 세션 정리 및 뽀모도로 검증 | 미완료 | 1~2시간 |
| 스톱워치 전체 revision 검증 | 미완료 | 1~2시간 |
| Firestore TLS 메모리 단기 방어 | 미완료 | 2~4시간 |
| `/hw/process` EC2 배포 상태 확인 | 불확실 | 1~2시간 |
| 음성 조회/완료/삭제 E2E | 미완료 | 2~5시간 |
| 학생/직장인 사용자 격리 검증 | fixture 완료, E2E 미완료 | 2~4시간 |
| UART → WSS → PostgreSQL E2E | RPi 필요 | 1~3시간 |
| 팝업/음성/뽀모도로 최종 LCD QA | 부분 완료 | 1~3시간 |
| AWS Todo REST 설계 및 ESP 전환 | 미구현 | 0.5~1.5일 |
| FirebaseJson 교체 및 Firebase 완전 제거 | 미구현 | 0.5~1일 |
| 회귀 테스트 및 코드 정리/커밋 | 미완료 | 0.5일 |

대략적인 총량:

- **로봇 단독 집중모드 데모 안정화:** 약 반나절~1일
- **음성까지 포함한 로봇 단독 테스트 완료:** 약 1~2일
- **Firestore 완전 제거까지 포함한 전체 마이그레이션:** 약 2~4 개발일
- 앱과 RPi 실기기 통합 검증은 장비 확보 이후 별도

---

# 14. 현재 완성도 평가

- WSS 연결/인증: **완료**
- NVS token 교체: **완료**
- WSS 집중 명령 송신: **완료**
- `focus_state` 공식 schema 동기화: **수정 후 재검증 필요**
- 뽀모도로 E2E: **부분 완료**
- 스톱워치 E2E: **미검증**
- UART 파싱 및 이벤트 코드: **구현 완료**
- UART AWS E2E: **미검증**
- ESP 음성 HTTPS 코드: **구현 완료**
- 음성 실제 E2E: **미검증**
- PostgreSQL 음성 인증/Todo 로컬 코드: **완료**
- EC2 HW 서버의 최신 코드 여부: **확인 필요**
- 테스트 fixture: **EC2 적용 완료**
- UI 디자인: **구현됐으나 최종 실기기 QA 필요**
- Firestore 완전 제거: **아직 하면 안 됨**
- 메모리 안정화: **미완료**

전체적으로 보면 코드 구현은 약 75~80% 수준이지만, 실제 장치·EC2·DB를 잇는 E2E 검증은 약 45~55% 수준이다.

---

# 15. 작업 트리 주의사항

현재 많은 변경사항이 아직 커밋되지 않았다.

주요 신규 파일:

- `src/aws_backend.h`
- `src/uart_rpi.h`
- `include/deskibot_tls.h`
- `server/register_test_device.py`
- `server/seed_test_fixtures.py`
- `server/todo_matching.py`
- `server/test_todo_matching.py`
- `server/EC2_DEPLOY_HW_AUTH.md`
- 팝업/음성/뽀모도로 이미지 C 자산

주요 수정 파일:

- `src/main.cpp`
- `src/firebase_handler.h`
- `src/screens/pomodoro.h`
- `src/screens/stopwatch.h`
- `src/screens/voice.h`
- `src/screens/popup.h`
- `server/server.py`
- `server/requirements.txt`
- `platformio.ini`
- 폰트 자산
- `include/lv_conf.h`

주의:

- `include/secrets.h`의 실제 값은 절대 출력하거나 커밋하지 말 것
- `.env` 파일을 출력하거나 덮어쓰지 말 것
- `server/__pycache__/`는 커밋 대상이 아님
- 사용자 UI 변경사항과 백엔드 변경사항이 한 작업 트리에 섞여 있음
- 정리 전에 기존 변경을 되돌리면 안 됨
- 커밋할 때 기능별로 나누는 것이 좋음

권장 커밋 분리:

1. AWS WSS/NVS/UART
2. 음성 HTTPS 및 PostgreSQL 인증
3. PostgreSQL Todo와 fixture
4. 팝업 UI/폰트
5. 뽀모도로 UI
6. 음성 UI
7. Firestore/AWS Todo REST 전환
8. 메모리 안정화 및 테스트

---

## 다음 AI에게 전달할 가장 짧은 핵심

> WSS device token 인증은 실제 ESP에서 성공했다. 25분 뽀모도로 `focus_start`도 전송됐지만 서버 `focus_state` schema를 ESP가 못 읽어 `session_id/revision`을 저장하지 못했고, 종료는 서버에 전송되지 않았다. `aws_backend.h`에 session/data/active_session 중첩 파서를 추가했고 PlatformIO 빌드는 성공했지만 아직 새 펌웨어 실기기 검증 전이다. 먼저 업로드 후 인증 snapshot과 누락 필드 진단 로그를 확인해야 한다. 음성 화면의 기존 Firestore fetch는 WSS와 TLS 메모리를 경쟁해 `esp-aes Failed to allocate memory`가 발생하고 Firestore 자체도 HTTP 403이다. Firestore는 Todo REST 대체 전까지 삭제하지 말되, 단기적으로 fetch를 제한하고 최종적으로 AWS Todo REST로 교체해야 한다. 실제 비밀값은 어떤 로그·채팅·Git에도 출력하지 않는다.