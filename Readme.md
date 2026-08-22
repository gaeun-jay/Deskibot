# Deskibot (Attenti)

**책상 위 AI 로봇 습관 트래커 — 졸음·스마트폰 사용을 실시간 감지하고 AI 습관 분석으로 집중 루틴을 개선합니다.**


## 프로젝트 소개

Deskibot(Attenti)은 2026 한이음 드림업 프로젝트로, 책상에 거치된 AI 로봇이 카메라를 통해 사용자의 졸음 여부와 스마트폰 사용을 실시간으로 감지합니다. 감지된 데이터는 AI 습관 분석 파이프라인을 거쳐 사용자에게 음성 피드백으로 전달되며, 모바일 플랫폼을 통해 집중 루틴을 시각적으로 관리할 수 있습니다. 비버 캐릭터를 적용하여 친근한 사용자 경험을 제공합니다.

**개발 기간** : 2026년 2월 ~ 진행중

---

## 팀 구성

| 이름 | 역할 |
|------|------|
| 정가은 | PM 및 HW 개발 리드 |
| 이다영 | HW 개발 |
| 윤다영 | Design(UI/UX) 및 SW 개발 |
| 윤나영 | SW/AI 개발 리드 |
| 최정아 | SW 개발 |

---

## 주요 기능

- **실시간 졸음 감지** : MediaPipe FaceMesh + Pose 기반으로 눈 감김·고개 숙임을 실시간 감지
- **스마트폰 사용 감지** : YOLOv 기반 객체 탐지로 스마트폰 사용 여부 인식
- **팬틸트 추적** : SG90 서보모터 2축 팬틸트로 사용자 위치 추적
- **AI 습관 분석 피드백** : 감지 데이터를 LLM으로 분석하여 TTS 음성 피드백 제공
- **AMOLED 디스플레이 UI** : ESP32-S3 LVGL 기반 알림 팝업, 뽀모도로, 스톱워치
- **STT 음성 입력** : 마이크를 통한 음성 명령 인식
- **모바일 플랫폼** : 집중 기록 시각화 및 습관 분석 리포트 제공
- **어드민 대시보드** : 사용자 관리 대시보드

---

## 기술 스택

![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi%205-C51A4A?style=flat-square&logo=raspberrypi&logoColor=white)
![ESP32](https://img.shields.io/badge/ESP32--S3-E7352C?style=flat-square&logo=espressif&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat-square&logo=python&logoColor=white)
![C++](https://img.shields.io/badge/C++-00599C?style=flat-square&logo=cplusplus&logoColor=white)
![AWS EC2](https://img.shields.io/badge/AWS%20EC2-232F3E?style=flat-square&logo=amazonec2&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?style=flat-square&logo=postgresql&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-02569B?style=flat-square&logo=flutter&logoColor=white)
![MediaPipe](https://img.shields.io/badge/MediaPipe-0097A7?style=flat-square&logo=google&logoColor=white)
![Figma](https://img.shields.io/badge/Figma-F24E1E?style=flat-square&logo=figma&logoColor=white)


| 분류 | 기술 |
|------|------|
| 메인 컴퓨터 | Raspberry Pi 5 8GB |
| 디스플레이 보드 | Waveshare ESP32-S3-Touch-AMOLED-1.75 |
| 졸음 감지 | MediaPipe FaceMesh + Pose |
| 스마트폰 감지 | MediaPipe ObjectDetector + EfficientDet-Lite0 |
| 팬틸트 | SG90 서보모터 2축 |
| 보드 간 통신 | UART (~1ms 레이턴시) |
| AI 피드백 | Claude + Google TTS |
| 음성 입력 | 마이크 + CLOVA STT (실패 시 Google 대체) |
| 임베디드 UI | LVGL |
| 백엔드 | AWS EC2 (nginx + Flask · FastAPI) + PostgreSQL 16 |
| 프론트엔드 | Flutter |
| 카메라 | Pi Camera Module 3 |

---

## 프로젝트 구조

"어디서 도는가"로 나눈다. 팀이 아니라 실행 위치 기준이라, 폴더 이름만 봐도
그 코드가 로봇 안에서 도는지 EC2에서 도는지 폰에서 도는지 알 수 있다.

```
Deskibot/
├── robot/              # 로봇 안에서 도는 것
│   ├── esp/            #   ESP32-S3 펌웨어 (PlatformIO)
│   │   ├── src/        #     LVGL 화면, 음성, UART, AWS 연동
│   │   ├── include/    #     오디오 코덱, 핀 정의
│   │   └── lib/        #     XPowersLib 등 외부 라이브러리
│   └── rpi/            #   Raspberry Pi 5
│       ├── detection/  #     졸음(FaceMesh)·스마트폰(EfficientDet) 감지
│       ├── tracking/   #     서보모터 팬틸트 추적
│       ├── comm/       #     ESP32 UART, 모니터링 스트림
│       └── tools/      #     서보 점검 스크립트
│
├── server/             # EC2에서 도는 것
│   └── hw/             #   음성 파이프라인 (Flask, :8000, /hw/*)
│       ├── bench/      #     STT 엔진 비교 벤치마크와 근거 데이터
│       └── sql/        #     HW가 쓰는 뷰 정의
│
└── docs/               # 설계 문서, 인수인계, 작업 로그
```

SW 파트(`server/sw/`, `app/`, `database/`)는 `sw-temp` 브랜치에서 개발 중이며
같은 구조로 합류할 예정이다.

---

## 시작하기

네 갈래가 독립적으로 돈다. 필요한 것만 준비하면 된다.

### robot/esp — ESP32-S3 펌웨어

PlatformIO에서 **`robot/esp` 폴더를 프로젝트로 연다** (저장소 루트가 아니다).

```bash
cd robot/esp
pio run              # 빌드
pio run -t upload    # 업로드
pio device monitor   # 시리얼 접속
```

업로드한 뒤 시리얼로 두 가지를 넣는다. **둘 다 NVS에 저장되어 재부팅·전원차단·
펌웨어 재업로드에도 유지되므로 한 번만 넣으면 된다.** 소스에 자격증명을 두지 않는
이유이자, 시연장 WiFi가 달라도 재플래싱하지 않는 이유다.

```
wifi <SSID> <비밀번호>          # 개방망이면 비밀번호 생략
→ [WiFi] 저장됨 SSID="..." (비밀번호 9자) — 재연결
→ [WiFi] ✅ IP: 192.168.0.42

token <device_token>
→ [Token] 저장됨 (len=43) — WS 재연결
→ [AWS WS] 인증 완료
```

부팅 시 저장된 WiFi가 없으면 주변 네트워크를 스캔해 목록을 보여주고 위 명령을
안내한다. SSID에 공백이 있어도 되지만(`wifi iPhone 15 mypassword`) 비밀번호에는
쓸 수 없다 — 마지막 공백을 기준으로 가르기 때문이다.

device token은 `server/hw/register_test_device.py`로 발급한다.

### robot/rpi — Raspberry Pi 5

`picamera2`는 libcamera 바인딩이 필요해 pip으로 설치되지 않는다.

```bash
sudo apt install -y python3-picamera2
cd robot/rpi
pip install -r requirements.txt
python main.py
```

**감지 모델 파일이 저장소에 없다.** 용량 때문에 `.gitignore` 처리되어 있으므로
`detection/efficientdet_lite0.tflite`를 따로 내려받아 넣어야 스마트폰 감지가 동작한다.

### server/hw — 음성 서버 (EC2)

```bash
bash server/hw/deploy_hw.sh <라벨>
```

로컬 검증 → 백업 → 전송 → 재시작 → health 확인 순으로 돌고, 실패하면 자동으로
직전 상태로 롤백한다. 백업은 `backups/<배포시각>-<라벨>`로 쌓인다.
자세한 절차와 수동 배포는 `server/hw/EC2_DEPLOY_HW_AUTH.md`를 본다.

### app — Flutter (sw-temp 브랜치)

```bash
flutter build apk
```

기본 서버 주소가 운영(`https://api.deskibot.co.kr`)이라 별도 옵션이 필요 없다.
로컬 서버로 붙일 때만 `--dart-define=API_BASE_URL=...`로 덮어쓴다.

---

## 자격증명

저장소에 자격증명을 커밋하지 않는다. `.gitignore`가 경로가 아니라 **이름으로**
막으므로(`secrets.h`, `.env`) 폴더 구조가 바뀌어도 규칙이 따라간다.

| 파일 | 용도 | 얻는 곳 |
|------|------|---------|
| `server/hw/.env` | Anthropic·CLOVA·DB 자격증명 | `server/hw/.env.example` 참고 |
| ESP device token | 로봇↔서버 인증 | `register_test_device.py`로 발급 후 시리얼 입력 |

---

