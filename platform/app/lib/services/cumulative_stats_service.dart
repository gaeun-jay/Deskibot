import 'package:deskibot/models/cumulative_stats_model.dart';
import 'package:deskibot/services/api_client.dart';

class CumulativeStatsService {

  /// periodIndex: 0=1주(7일/7버킷), 1=1달(30일/4버킷), 2=3달(90일/3버킷),
  ///              3=6달(180일/6버킷), 4=1년(365일/4버킷)
  Future<CumulativeStatsModel?> fetchStats(int periodIndex) async {
    // 사용자 확인은 서버가 토큰으로 한다. 토큰이 없으면 아래에서 401 이
    // 나고 needsLogin 으로 걸러진다.
    final today = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    final startDate = today.subtract(Duration(days: _periodDays(periodIndex) - 1));
    final startStr  = _fmt(startDate);
    final endStr    = _fmt(today);

    // 서버가 일자별로 이미 집계해 준다. 예전에는 세션·할일 원본 문서를
    // 통째로 받아 앱에서 셌지만, 이제 /api/stats/range 한 번이면 된다.
    final Map<String, dynamic> range;
    try {
      range = Map<String, dynamic>.from(await ApiClient().get(
        '/api/stats/range',
        query: {'start': startStr, 'end': endStr},
      ) as Map);
    } on ApiException catch (e) {
      if (e.needsLogin) return null;
      rethrow;
    }

    final serverDays = (range['days'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final count  = _bucketCount(periodIndex);
    final pomoDur = List<int>.filled(count, 0);
    final swDur   = List<int>.filled(count, 0);
    final dCnt    = List<int>.filled(count, 0);
    final dDur    = List<int>.filled(count, 0);
    final pCnt    = List<int>.filled(count, 0);
    final pDur    = List<int>.filled(count, 0);
    final tTotal  = List<int>.filled(count, 0);
    final tDone   = List<int>.filled(count, 0);
    final slots   = List.generate(count, (_) => <String, SlotStats>{
      'dawn': SlotStats.empty, 'morning': SlotStats.empty,
      'afternoon': SlotStats.empty, 'night': SlotStats.empty,
    });

    // 서버는 전부 초 단위. 화면은 분이므로 여기서 변환한다.
    int toMin(dynamic sec) => ((sec as int? ?? 0) / 60).round();

    for (final day in serverDays) {
      final b = _bucket(day['date'] as String? ?? '', periodIndex, today);
      if (b == null) continue;

      pomoDur[b] += toMin(day['pomodoro_duration_sec']);
      swDur[b]   += toMin(day['stopwatch_duration_sec']);
      dCnt[b]    += day['drowsy_count'] as int? ?? 0;
      dDur[b]    += toMin(day['drowsy_duration_sec']);
      pCnt[b]    += day['phone_count'] as int? ?? 0;
      pDur[b]    += toMin(day['phone_duration_sec']);
      tTotal[b]  += day['todo_total'] as int? ?? 0;
      tDone[b]   += day['todo_done'] as int? ?? 0;

      final timeSlots = Map<String, dynamic>.from(
        (day['time_slots'] as Map?) ?? {},
      );

      for (final entry in timeSlots.entries) {
        final v = Map<String, dynamic>.from(entry.value as Map);
        final prev = slots[b][entry.key];
        if (prev == null) continue;

        slots[b][entry.key] = SlotStats(
          drowsyCount: prev.drowsyCount + (v['drowsy_count'] as int? ?? 0),
          phoneCount:  prev.phoneCount  + (v['phone_count'] as int? ?? 0),
        );
      }
    }

    final labels = _labels(periodIndex, today);
    final days = List.generate(count, (i) => DayStats(
      date:             _fmt(today.subtract(Duration(days: count - 1 - i))),
      label:            labels[i],
      pomodoroMinutes:  pomoDur[i],
      stopwatchMinutes: swDur[i],
      drowsyCount:      dCnt[i],
      drowsyDuration:   dDur[i],
      phoneCount:       pCnt[i],
      phoneDuration:    pDur[i],
      todoTotal:        tTotal[i],
      todoDone:         tDone[i],
      timeSlots:        slots[i],
    ));

    return _aggregate(days);
  }

  /// 기간에 맞는 누적 분석(패턴 + 루틴) 읽기
  /// 0=1주(YYYY-Www)      → 매주 월요일 갱신
  /// 1=1달(YYYY-MM)       → 매월 1일 갱신
  /// 2=3달(YYYY-MM_3m)    → 매월 1일 갱신
  /// 3=6달(YYYY-MM_6m)    → 매월 1일 갱신
  /// 4=1년(YYYY-Q{N}_1y)  → 분기마다 갱신
  ///
  /// 서버 배치가 수동 트리거라 정확한 갱신 시점을 보장하지 않으므로,
  /// 이번 기간 분석이 아직 없으면 바로 직전 기간 분석으로 대체한다.
  /// periodIndex → 서버 period_type.
  /// Node 시절의 '6monthly' 는 스키마 CHECK 에 맞춰 'half_yearly' 가 됐다.
  static const _periodTypes = [
    'weekly',
    'monthly',
    'quarterly',
    'half_yearly',
    'yearly',
  ];

  Future<CumulativeAnalysisModel?> fetchAnalysis(int periodIndex) async {
    if (periodIndex < 0 || periodIndex >= _periodTypes.length) return null;

    final periodType = _periodTypes[periodIndex];

    try {
      // 서버가 그 기간의 가장 최근 분석을 알아서 돌려준다. 문서 ID 를
      // 만들어 맞춰보던 로직(이번 기간 없으면 직전 기간)이 필요 없어졌다.
      final res = await ApiClient()
          .get('/api/analysis/cumulative/$periodType/latest');
      final map = Map<String, dynamic>.from(res as Map);

      return CumulativeAnalysisModel.fromMap(
        '${map['period_start']}~${map['period_end']}',
        map,
        periodLabel: _periodLabel(periodIndex, map['period_start'] as String?),
      );
    } on ApiException catch (e) {
      // 아직 생성된 분석이 없거나 로그인 전.
      if (e.statusCode == 404 || e.needsLogin) return null;
      rethrow;
    }
  }

  /// 리포트 배지에 쓰는 기간 라벨.
  ///
  /// 반드시 **서버가 준 period_start** 로 만든다. 예전에는 DateTime.now() 로
  /// 계산했는데, 서버가 리포트 기간을 "직전 달력 기간"(지난주 · 지난달 …)으로
  /// 바꾸면서 라벨만 한 주/한 달 앞서게 됐다. 8/10~8/16 리포트에 "8/17 주 기준"
  /// 이라고 붙는 식이다.
  String _periodLabel(int periodIndex, String? periodStart) {
    final start = periodStart == null ? null : DateTime.tryParse(periodStart);
    if (start == null) return '';

    switch (periodIndex) {
      case 0:
        return '${start.month}/${start.day} 주';
      case 1:
        return '${start.month}월';
      case 2:
        return '${((start.month - 1) ~/ 3) + 1}분기';
      case 3:
        return start.month <= 6 ? '상반기' : '하반기';
      default:
        return '${start.year}년';
    }
  }


  // ── 집계 ─────────────────────────────────────────────────────

  CumulativeStatsModel _aggregate(List<DayStats> days) {
    final totalFocus = days.fold(0, (s, d) => s + d.focusMinutes);
    final totalDist  = days.fold(0, (s, d) => s + d.totalDistractions);

    final activeDays = days.where((d) => d.focusMinutes > 0).toList();
    final avgFocusRate = activeDays.isEmpty
        ? 0.0
        : activeDays.fold(0.0, (s, d) => s + d.focusRate) / activeDays.length;

    final todoDays = days.where((d) => d.todoTotal > 0).toList();
    final avgAchievementRate = todoDays.isEmpty
        ? 0.0
        : todoDays.fold(0.0, (s, d) => s + d.achievementRate) / todoDays.length;

    return CumulativeStatsModel(
      totalFocusMinutes:   totalFocus,
      avgFocusRate:        avgFocusRate,
      avgAchievementRate:  avgAchievementRate,
      totalDistractions:   totalDist,
      days:                days,
    );
  }

  // ── 헬퍼 ─────────────────────────────────────────────────────

  /// 기간 전체 일수
  int _periodDays(int p) =>
      const [7, 30, 90, 180, 365][p.clamp(0, 4)];

  /// 차트 버킷(칼럼) 수
  int _bucketCount(int p) =>
      const [7, 4, 3, 6, 4][p.clamp(0, 4)];

  /// 날짜 문자열 → 버킷 인덱스 (0=가장 오래된 버킷)
  int? _bucket(String dateStr, int periodIndex, DateTime today) {
    if (dateStr.length < 10) return null;
    final d = DateTime(
      int.parse(dateStr.substring(0, 4)),
      int.parse(dateStr.substring(5, 7)),
      int.parse(dateStr.substring(8, 10)),
    );
    final ago = today.difference(d).inDays;
    switch (periodIndex) {
      case 0: // 7일 → 7버킷
        if (ago < 0 || ago > 6) return null;
        return 6 - ago;
      case 1: // 30일 → 4버킷 (주 단위)
        if (ago < 0 || ago > 29) return null;
        return 3 - (ago ~/ 7).clamp(0, 3);
      case 2: // 90일 → 3버킷 (월 단위)
        if (ago < 0 || ago > 89) return null;
        return 2 - (ago ~/ 30).clamp(0, 2);
      case 3: // 180일 → 6버킷 (월 단위)
        if (ago < 0 || ago > 179) return null;
        return 5 - (ago ~/ 30).clamp(0, 5);
      case 4: // 365일 → 4버킷 (분기 단위)
        if (ago < 0 || ago > 364) return null;
        return 3 - (ago ~/ 91).clamp(0, 3);
      default:
        return null;
    }
  }

  /// x축 레이블
  List<String> _labels(int periodIndex, DateTime today) {
    const wd = ['월', '화', '수', '목', '금', '토', '일'];
    switch (periodIndex) {
      case 0:
        return List.generate(7, (i) {
          final d = today.subtract(Duration(days: 6 - i));
          return wd[d.weekday - 1];
        });
      case 1:
        return ['1주', '2주', '3주', '4주'];
      case 2:
        return List.generate(3, (i) {
          final m = (today.month - (2 - i) - 1) % 12 + 1;
          return '$m월';
        });
      case 3:
        return List.generate(6, (i) {
          final m = (today.month - (5 - i) - 1) % 12 + 1;
          return '$m월';
        });
      case 4:
        return ['1분기', '2분기', '3분기', '4분기'];
      default:
        return [];
    }
  }



  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
