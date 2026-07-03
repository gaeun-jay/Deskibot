class PatternItem {
  final String type;  // "focus" | "distraction" | "todo"
  final String title;
  final String body;

  const PatternItem({required this.type, required this.title, required this.body});

  factory PatternItem.fromMap(Map<String, dynamic> map) => PatternItem(
        type: map['type'] as String? ?? '',
        title: map['title'] as String? ?? '',
        body: map['body'] as String? ?? '',
      );
}

class RoutineItem {
  final String time;   // "HH:MM"
  final String label;
  final String body;

  const RoutineItem({required this.time, required this.label, this.body = ''});

  factory RoutineItem.fromMap(Map<String, dynamic> map) => RoutineItem(
        time: map['time'] as String? ?? '',
        label: map['label'] as String? ?? '',
        body: map['body'] as String? ?? '',
      );
}

class CumulativeAnalysisModel {
  final String periodId;
  final String periodLabel;  // 화면 표시용 기간 라벨 (예: "7월", "2분기")
  final String? summary;   // 한 줄 취약점 요약
  final List<PatternItem> patterns;
  final List<RoutineItem> routine;

  const CumulativeAnalysisModel({
    required this.periodId,
    required this.periodLabel,
    this.summary,
    required this.patterns,
    required this.routine,
  });

  factory CumulativeAnalysisModel.fromMap(
    String periodId,
    Map<String, dynamic> map, {
    required String periodLabel,
  }) =>
      CumulativeAnalysisModel(
        periodId: periodId,
        periodLabel: periodLabel,
        summary: map['summary'] as String?,
        patterns: (map['patterns'] as List? ?? [])
            .map((e) => PatternItem.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList(),
        routine: (map['routine'] as List? ?? [])
            .map((e) => RoutineItem.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

class CumulativeStatsModel {
  final int totalFocusMinutes;      // 누적 집중 (분)
  final double avgFocusRate;        // 평균 집중률 (0~100)
  final double avgAchievementRate;  // 평균 달성률 (0~100)
  final int totalDistractions;      // 총 방해감지 횟수
  final List<DayStats> days;        // 기간 내 날짜별 데이터

  const CumulativeStatsModel({
    required this.totalFocusMinutes,
    required this.avgFocusRate,
    required this.avgAchievementRate,
    required this.totalDistractions,
    required this.days,
  });
}

class SlotStats {
  final int drowsyCount;
  final int phoneCount;

  const SlotStats({required this.drowsyCount, required this.phoneCount});

  int get total => drowsyCount + phoneCount;

  factory SlotStats.fromMap(Map<String, dynamic> map) => SlotStats(
        drowsyCount: (map['drowsy_count'] as num? ?? 0).toInt(),
        phoneCount: (map['phone_count'] as num? ?? 0).toInt(),
      );

  static const empty = SlotStats(drowsyCount: 0, phoneCount: 0);
}

class DayStats {
  final String date;
  final String label;
  final int pomodoroMinutes;
  final int stopwatchMinutes;
  final int drowsyCount;
  final int drowsyDuration;
  final int phoneCount;
  final int phoneDuration;
  final int todoTotal;
  final int todoDone;
  // 시간대별 방해 감지. keys: dawn / morning / afternoon / night
  final Map<String, SlotStats> timeSlots;

  const DayStats({
    required this.date,
    required this.label,
    required this.pomodoroMinutes,
    required this.stopwatchMinutes,
    required this.drowsyCount,
    required this.drowsyDuration,
    required this.phoneCount,
    required this.phoneDuration,
    required this.todoTotal,
    required this.todoDone,
    required this.timeSlots,
  });

  int get focusMinutes => pomodoroMinutes + stopwatchMinutes;
  int get totalDistractions => drowsyCount + phoneCount;

  double get focusRate {
    if (focusMinutes == 0) return 0;
    final effective = focusMinutes - drowsyDuration - phoneDuration;
    return (effective / focusMinutes * 100).clamp(0.0, 100.0);
  }

  double get achievementRate {
    if (todoTotal == 0) return 0;
    return (todoDone / todoTotal * 100).clamp(0.0, 100.0);
  }

  factory DayStats.fromMap(String date, String label, Map<String, dynamic> map) {
    final rawSlots = map['time_slots'] as Map<String, dynamic>? ?? {};
    final slots = <String, SlotStats>{};
    for (final key in ['dawn', 'morning', 'afternoon', 'night']) {
      final s = rawSlots[key] as Map<String, dynamic>?;
      slots[key] = s != null ? SlotStats.fromMap(s) : SlotStats.empty;
    }
    return DayStats(
      date: date,
      label: label,
      pomodoroMinutes: (map['pomodoro_duration'] as num? ?? 0).toInt(),
      stopwatchMinutes: (map['stopwatch_duration'] as num? ?? 0).toInt(),
      drowsyCount: (map['drowsy_count'] as num? ?? 0).toInt(),
      drowsyDuration: (map['drowsy_duration'] as num? ?? 0).toInt(),
      phoneCount: (map['phone_count'] as num? ?? 0).toInt(),
      phoneDuration: (map['phone_duration'] as num? ?? 0).toInt(),
      todoTotal: (map['todo_total'] as num? ?? 0).toInt(),
      todoDone: (map['todo_done'] as num? ?? 0).toInt(),
      timeSlots: slots,
    );
  }

  factory DayStats.empty(String date, String label) {
    return DayStats(
      date: date, label: label,
      pomodoroMinutes: 0, stopwatchMinutes: 0,
      drowsyCount: 0, drowsyDuration: 0,
      phoneCount: 0, phoneDuration: 0,
      todoTotal: 0, todoDone: 0,
      timeSlots: {
        'dawn': SlotStats.empty, 'morning': SlotStats.empty,
        'afternoon': SlotStats.empty, 'night': SlotStats.empty,
      },
    );
  }
}
