import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:deskibot/models/cumulative_stats_model.dart';
import 'package:deskibot/services/auth_service.dart';

// ISO 주차 ID: "YYYY-Www" (서버와 동일 로직)
String currentIsoWeekId() => _isoWeekId(DateTime.now());

String _isoWeekId(DateTime date) {
  final thursday = date.add(Duration(days: 4 - (date.weekday == 7 ? 0 : date.weekday)));
  final yearStart = DateTime(thursday.year, 1, 1);
  final week = ((thursday.difference(yearStart).inDays + 1) / 7).ceil();
  return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
}

class CumulativeStatsService {
  final _db = FirebaseFirestore.instance;

  /// periodIndex: 0=1주(7일/7버킷), 1=1달(30일/4버킷), 2=3달(90일/3버킷),
  ///              3=6달(180일/6버킷), 4=1년(365일/4버킷)
  Future<CumulativeStatsModel?> fetchStats(int periodIndex) async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) return null;

    final today = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    final startDate = today.subtract(Duration(days: _periodDays(periodIndex) - 1));
    final startStr  = _fmt(startDate);
    final endStr    = _fmt(today);

    // focus_sessions + todos 병렬 읽기
    final results = await Future.wait([
      _db.collection('users').doc(uid)
          .collection('focus_sessions')
          .where('start_date', isGreaterThanOrEqualTo: startStr)
          .where('start_date', isLessThanOrEqualTo: endStr)
          .get(),
      _db.collection('users').doc(uid)
          .collection('todos')
          .where('date', isGreaterThanOrEqualTo: startStr)
          .where('date', isLessThanOrEqualTo: endStr)
          .get(),
    ]);

    final sessionsSnap = results[0];
    final todosSnap    = results[1];

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

    for (final doc in sessionsSnap.docs) {
      final data = doc.data();
      final dateStr = data['start_date'] as String? ?? '';
      final b = _bucket(dateStr, periodIndex, today);
      if (b == null) continue;

      final type = data['type'] as String? ?? '';
      final dur  = data['actual_duration'] as int? ?? 0;
      if (type == 'pomodoro')  pomoDur[b] += dur;
      if (type == 'stopwatch') swDur[b]   += dur;

      final drowsyEvs = (data['drowsy_events'] as List?) ?? [];
      final phoneEvs  = (data['phone_events']  as List?) ?? [];
      dCnt[b] += drowsyEvs.length;
      dDur[b] += _sumDur(drowsyEvs);
      pCnt[b] += phoneEvs.length;
      pDur[b] += _sumDur(phoneEvs);

      final slot = _slotKey(data['start_time'] as String?);
      final prev = slots[b][slot]!;
      slots[b][slot] = SlotStats(
        drowsyCount: prev.drowsyCount + drowsyEvs.length,
        phoneCount:  prev.phoneCount  + phoneEvs.length,
      );
    }

    for (final doc in todosSnap.docs) {
      final data = doc.data();
      final dateStr = data['date'] as String? ?? '';
      final b = _bucket(dateStr, periodIndex, today);
      if (b == null) continue;
      tTotal[b]++;
      if (data['is_done'] == true) tDone[b]++;
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
  Future<CumulativeAnalysisModel?> fetchAnalysis(int periodIndex) async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) return null;

    final now = DateTime.now();
    final current = _analysisPeriod(periodIndex, now);
    if (current == null) return null;

    final analysisCol = _db.collection('users').doc(uid).collection('analysis');

    var doc = await analysisCol.doc(current.id).get();
    var period = current;

    if (!doc.exists || doc.data()?['type'] != 'cumulative') {
      final previous = _previousAnalysisPeriod(periodIndex, now);
      if (previous != null) {
        doc = await analysisCol.doc(previous.id).get();
        period = previous;
      }
    }

    if (!doc.exists || doc.data()?['type'] != 'cumulative') return null;
    return CumulativeAnalysisModel.fromMap(doc.id, doc.data()!, periodLabel: period.label);
  }

  /// periodIndex + 기준 날짜 → (문서 id, 화면 표시용 라벨)
  ({String id, String label})? _analysisPeriod(int periodIndex, DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    switch (periodIndex) {
      case 0:
        final monday = date.subtract(Duration(days: date.weekday - 1));
        return (id: _isoWeekId(date), label: '${monday.month}/${monday.day} 주');
      case 1:
        return (id: '${date.year}-$mm', label: '${date.month}월');
      case 2:
        return (id: '${date.year}-${mm}_3m', label: '${date.month}월');
      case 3:
        return (id: '${date.year}-${mm}_6m', label: '${date.month}월');
      case 4:
        final q = ((date.month - 1) ~/ 3) + 1;
        return (id: '${date.year}-Q${q}_1y', label: '$q분기');
      default:
        return null;
    }
  }

  /// 직전 갱신 주기의 (문서 id, 라벨). 이번 기간 문서가 없을 때의 대체용.
  ({String id, String label})? _previousAnalysisPeriod(int periodIndex, DateTime now) {
    switch (periodIndex) {
      case 0:
        return _analysisPeriod(0, now.subtract(const Duration(days: 7)));
      case 1:
      case 2:
      case 3:
        return _analysisPeriod(periodIndex, DateTime(now.year, now.month - 1, 1));
      case 4:
        return _analysisPeriod(4, DateTime(now.year, now.month - 3, 1));
      default:
        return null;
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

  /// HH:MM → 시간대 키
  String _slotKey(String? startTime) {
    if (startTime == null) return 'morning';
    final h = int.tryParse(startTime.split(':')[0]) ?? 9;
    if (h < 6)  return 'dawn';
    if (h < 12) return 'morning';
    if (h < 18) return 'afternoon';
    return 'night';
  }

  /// 이벤트 목록의 total_duration 합계
  int _sumDur(List events) =>
      events.fold(0, (s, e) => s + ((e as Map)['total_duration'] as int? ?? 0));

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
