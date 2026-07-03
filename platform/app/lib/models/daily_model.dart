class DailyModel {
  final String date;           // "2026-06-25"
  final int drowsyCount;       // 졸음 횟수
  final int drowsyDuration;    // 졸음 시간
  final int phoneCount;        // 핸드폰 감지 횟수
  final int phoneDuration;     // 핸드폰 사용 시간
  final int pomodoroCount;     // 뽀모도로 횟수
  final int pomodoroDuration;  // 뽀모도로 시간 
  final int stopwatchCount;    // 스톱워치 횟수
  final int stopwatchDuration; // 스톱워치 시간
  

  const DailyModel({
    required this.date,
    required this.drowsyCount,
    required this.drowsyDuration,
    required this.phoneCount,
    required this.phoneDuration,
    required this.pomodoroCount,
    required this.pomodoroDuration,
    required this.stopwatchCount,
    required this.stopwatchDuration,
  });

  factory DailyModel.fromMap(String date, Map<String, dynamic> map) {
    return DailyModel(
      date: date,
      drowsyCount: map['drowsy_count'] as int? ?? 0,
      drowsyDuration: map['drowsy_duration'] as int? ?? 0,
      phoneCount: map['phone_count'] as int? ?? 0,
      phoneDuration: map['phone_duration'] as int? ?? 0,
      pomodoroCount: map['pomodoro_count'] as int? ?? 0,
      pomodoroDuration: map['pomodoro_duration'] as int? ?? 0,
      stopwatchCount: map['stopwatch_count'] as int? ?? 0,
      stopwatchDuration: map['stopwatch_duration'] as int? ?? 0,
    );
  }
}