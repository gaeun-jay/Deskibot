// Firestore focus_sessions 문서를 타임테이블 블록으로 매핑하는 모델
// 저장 필드: type, title, date, start_time, end_date, end_time, actual_duration
class FocusBlock {
  final String id;
  final String date; // "YYYY-MM-DD"
  final String startTime; // "HH:mm"
  final String endTime; // "HH:mm"
  final String sessionType; // 'pomodoro' | 'stopwatch'
  final String label; // 사용자가 수정 가능한 제목 (기본: '뽀모도로'/'스톱워치')
  final int durationMin;

  const FocusBlock({
    required this.id,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.sessionType,
    required this.label,
    required this.durationMin,
  });

  int get startMinutes => _toMinutes(startTime);
  int get endMinutes => _toMinutes(endTime);

  static int _toMinutes(String time) {
    final parts = time.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  factory FocusBlock.fromMap(String id, Map<String, dynamic> map) {
    return FocusBlock(
      id: id,
      date: map['date'] as String? ?? '',
      startTime: map['start_time'] as String? ?? '00:00',
      endTime: map['end_time'] as String? ?? '00:00',
      sessionType: map['type'] as String? ?? 'pomodoro',
      label: map['title'] as String? ?? '집중 세션',
      durationMin: map['actual_duration'] as int? ?? 0,
    );
  }
}
