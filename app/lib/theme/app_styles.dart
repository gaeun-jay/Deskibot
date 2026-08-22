import 'package:flutter/material.dart';

/// 헤더 뒤에 깔리는 공용 배경 그라데이션 (진한 파랑 -> 흰색).
/// 일간 분석 페이지의 톤을 기준으로 홈/누적/집중/데일리로그 화면에 공통 적용한다.
const kAppBackgroundGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [
    Color(0xFF5097FF),
    Color(0xFF7DB2FF),
    Color(0xFFA5CAFF),
    Color(0xFFD2E4FF),
    Color(0xFFF5F9FF),
    Color(0xFFFFFFFF),
  ],
  stops: [0.0, 0.2, 0.35, 0.5, 0.8, 1.0],
);

/// 화면 헤더의 큰 타이틀 (예: "일정 관리", "누적 분석", "일간 분석").
const kHeaderTitleStyle = TextStyle(
  fontSize: 26,
  fontWeight: FontWeight.bold,
  color: Colors.white,
  shadows: [
    Shadow(offset: Offset(1, 1), blurRadius: 1, color: Color(0x80000000)),
  ],
);

/// 헤더 타이틀 아래 보조 텍스트 (설명 문구, 날짜 등).
const kHeaderSubtitleStyle = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w600,
  color: Colors.white,
);

/// 카드 내부 섹션 타이틀 (예: "오늘 할일", "키워드별 요약", "반복 패턴").
const kCardTitleStyle = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w600,
  color: Color(0xFF6286B8),
);

/// 헤더에 들어가는 캐릭터 마스코트 이미지의 공용 크기.
const double kHeaderCharacterSize = 100.0;
