// Firestore focus_sessions 문서를 타임테이블 블록으로 매핑하는 모델
// 저장 필드: type, title, date, start_time, end_date, end_time, actual_duration
class FocusBlock {
  final String id;
  final String date; // "YYYY-MM-DD"
  final String startTime; // "HH:mm"
  final String endTime; // "HH:mm"
  final String sessionType; // 'pomodoro' | 'stopwatch'
  final String label; // 사용자가 수정 가능한 제목 (기본: '뽀모도로'/'스톱워치')

  /// 표시용 실행 시간(분). 반올림이라 25분 세션이 24분 50초여도 25분으로 보인다.
  final int durationMin;

  /// 서버가 준 실행 시간(초) 원본.
  ///
  /// "10분 미만은 숨긴다" 같은 경계 판정에는 반드시 이 값을 쓴다. durationMin 은
  /// 반올림이라 9분 30초가 10분으로 잡혀 기준이 30초씩 밀린다.
  final int durationSec;

  /// 서버의 세션 종료 상태. 'completed' | 'incomplete' | 'interrupted'
  ///
  /// interrupted 는 자리 비움이 감지돼 시스템이 강제로 끊은 세션이다.
  /// 그때까지 실제로 집중한 시간은 그대로 남으므로 타임테이블에도 그리되,
  /// 정상 종료와 구분되게 다른 색으로 표시한다.
  final String status;

  const FocusBlock({
    required this.id,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.sessionType,
    required this.label,
    required this.durationMin,
    this.durationSec = 0,
    this.status = 'completed',
  });

  bool get isInterrupted => status == 'interrupted';

  int get startMinutes => _toMinutes(startTime);
  int get endMinutes => _toMinutes(endTime);

  static int _toMinutes(String time) {
    final parts = time.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  factory FocusBlock.fromMap(String id, Map<String, dynamic> map) {
    final startTime   = map['start_time'] as String? ?? '00:00';
    final actualDur   = map['actual_duration'] as int? ?? 0;
    final rawEndTime  = map['end_time'] as String?;

    // end_time이 없으면 start_time + actual_duration으로 추정
    final endTime = (rawEndTime != null && rawEndTime.isNotEmpty)
        ? rawEndTime
        : _addMinutes(startTime, actualDur);

    return FocusBlock(
      id: id,
      date: map['date'] as String? ?? '',
      startTime: startTime,
      endTime: endTime,
      sessionType: map['type'] as String? ?? 'pomodoro',
      label: map['title'] as String? ?? '집중 세션',
      durationMin: actualDur,
    );
  }

  /// "HH:mm" 문자열에 minutes를 더한 결과를 "HH:mm"으로 반환 (자정 초과 시 wrap)
  static String _addMinutes(String startTime, int minutes) {
    final parts    = startTime.split(':');
    final startMin = int.parse(parts[0]) * 60 + int.parse(parts[1]);
    final endMin   = (startMin + minutes) % (24 * 60);
    final hh       = (endMin ~/ 60).toString().padLeft(2, '0');
    final mm       = (endMin % 60).toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}
