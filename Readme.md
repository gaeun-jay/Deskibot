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
![Firebase](https://img.shields.io/badge/Firebase-FFCA28?style=flat-square&logo=firebase&logoColor=black)
![MediaPipe](https://img.shields.io/badge/MediaPipe-0097A7?style=flat-square&logo=google&logoColor=white)
![Figma](https://img.shields.io/badge/Figma-F24E1E?style=flat-square&logo=figma&logoColor=white)


| 분류 | 기술 |
|------|------|
| 메인 컴퓨터 | Raspberry Pi 5 8GB |
| 디스플레이 보드 | Waveshare ESP32-S3-Touch-AMOLED-1.75 |
| 졸음 감지 | MediaPipe FaceMesh + Pose |
| 스마트폰 감지 | YOLO |
| 팬틸트 | SG90 서보모터 2축 |
| 보드 간 통신 | UART (~1ms 레이턴시) |
| AI 피드백 | LLM + TTS |
| 음성 입력 | 마이크 + STT |
| 임베디드 UI | LVGL |
| 백엔드 | Firebase Realtime DB |
| 프론트엔드 | 모바일 플랫폼 + 어드민 대시보드 |
| 카메라 | Pi Camera Module 3 |

---

## 프로젝트 구조

```
Deskibot/
├── rpi/                # Raspberry Pi 5 코드
│   ├── detection/      # MediaPipe(졸음), YOLO(스마트폰) 감지
│   ├── tracking/       # 서보모터 팬틸트 추적
│   ├── feedback/       # LLM 습관 분석 + TTS 피드백
│   └── uart/           # ESP32-S3 통신
│
├── esp/                # ESP32-S3 코드
│   ├── ui/             # LVGL UI, 알림 팝업, 뽀모도로/스톱워치
│   ├── stt/            # 마이크 + STT
│   └── uart/           # RPi 통신
│
├── platform/           # 모바일 플랫폼
│   ├── mobile/         # 사용자 모바일 화면
│   └── dashboard/      # 어드민 대시보드
│
├── firebase/           # Firebase 스키마, Rules, 설정
│
└── docs/               # 설계 문서, 회의록
```

---

