// TODO: 개발용 임시 시드 데이터 서비스. 실제 서비스 전 삭제할 것.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:deskibot/services/auth_service.dart';

class SeedService {
  final _db = FirebaseFirestore.instance;

  String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 오늘 기준 7일치 더미 데이터를 Firestore에 씀.
  /// focus_sessions, todos → 서브컬렉션
  /// aggregations         → users/{uid}/aggregations/{date}
  /// analysis_daily       → users/{uid}/analysis_daily/{date}
  /// analysis_cumulative  → users/{uid}/analysis_cumulative/{periodId}
  Future<void> seedOneWeek() async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) throw Exception('로그인 필요');

    final userRef = _db.collection('users').doc(uid);
    final today = DateTime.now();

    // 7일치 날짜 (6일 전 ~ 오늘)
    final dates = List.generate(7, (i) => today.subtract(Duration(days: 6 - i)));

    // 날짜별 시드 정의
    final daySeeds = _buildDaySeeds(dates);

    // Batch 단위로 나눠서 쓰기 (Firestore 500 ops 제한)
    var batch = _db.batch();
    int opCount = 0;

    for (final day in daySeeds) {
      final date = day['date'] as String;

      // ── focus_sessions (서브컬렉션) ──────────────
      final sessions = day['sessions'] as List<Map<String, dynamic>>;
      for (final s in sessions) {
        final ref = userRef.collection('focus_sessions').doc();
        batch.set(ref, s);
        opCount++;
        if (opCount >= 490) {
          await batch.commit();
          batch = _db.batch();
          opCount = 0;
        }
      }

      // ── todos (서브컬렉션) ───────────────────────
      final todos = day['todos'] as List<Map<String, dynamic>>;
      for (final t in todos) {
        final ref = userRef.collection('todos').doc();
        batch.set(ref, t);
        opCount++;
        if (opCount >= 490) {
          await batch.commit();
          batch = _db.batch();
          opCount = 0;
        }
      }

      // ── stats/aggregations/daily/{date} → 서브컬렉션 ────────────
      // users/{uid}/stats(C)/aggregations(D)/daily(C)/{date}(D)
      final aggRef = userRef
          .collection('stats')
          .doc('aggregations')
          .collection('daily')
          .doc(date);
      batch.set(aggRef, day['aggregation'] as Map<String, dynamic>);
      opCount++;
    }

    // ── analysis_started_date → 유저 문서 최상위 필드 ───────────────
    batch.set(userRef, {'analysis_started_date': _dateStr(dates.first)},
        SetOptions(merge: true));

    await batch.commit();

    // ── analysis/{date} → 배치 밖에서 개별 쓰기 ─────────────────────
    // users/{uid}/analysis(C)/{date}(D)
    for (final day in daySeeds) {
      final date = day['date'] as String;
      await userRef.collection('analysis').doc(date).set({
        'type': 'daily',
        ...(day['analysis_daily'] as Map<String, dynamic>),
      });
    }
  }

  /// 오늘 기준 365일(1년)치 더미 데이터를 Firestore에 씀 (7가지 패턴 순환).
  Future<void> seedOneYear() async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) throw Exception('로그인 필요');

    final userRef = _db.collection('users').doc(uid);
    final today = DateTime.now();
    final dates = List.generate(365, (i) => today.subtract(Duration(days: 364 - i)));

    final patternFns = [_day0, _day1, _day2, _day3, _day4, _day5, _dayRest];
    final dayDataList = List.generate(365, (i) => patternFns[i % 7](dates[i]));

    var batch = _db.batch();
    int opCount = 0;

    for (final day in dayDataList) {
      final date = day['date'] as String;

      for (final s in day['sessions'] as List<Map<String, dynamic>>) {
        batch.set(userRef.collection('focus_sessions').doc(), s);
        opCount++;
        if (opCount >= 490) {
          await batch.commit();
          batch = _db.batch();
          opCount = 0;
        }
      }

      for (final t in day['todos'] as List<Map<String, dynamic>>) {
        batch.set(userRef.collection('todos').doc(), t);
        opCount++;
        if (opCount >= 490) {
          await batch.commit();
          batch = _db.batch();
          opCount = 0;
        }
      }

      final aggRef = userRef
          .collection('stats')
          .doc('aggregations')
          .collection('daily')
          .doc(date);
      batch.set(aggRef, day['aggregation'] as Map<String, dynamic>);
      opCount++;
      if (opCount >= 490) {
        await batch.commit();
        batch = _db.batch();
        opCount = 0;
      }
    }

    batch.set(userRef, {'analysis_started_date': _dateStr(dates.first)},
        SetOptions(merge: true));
    await batch.commit();

    for (final day in dayDataList) {
      final date = day['date'] as String;
      await userRef.collection('analysis').doc(date).set({
        'type': 'daily',
        ...(day['analysis_daily'] as Map<String, dynamic>),
      });
    }
  }

  /// 오늘 기준 180일(약 6개월)치 더미 데이터를 Firestore에 씀 (7가지 패턴 순환).
  Future<void> seedSixMonths() async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) throw Exception('로그인 필요');

    final userRef = _db.collection('users').doc(uid);
    final today = DateTime.now();
    final dates = List.generate(180, (i) => today.subtract(Duration(days: 179 - i)));

    // 7가지 패턴 순환 (마지막은 휴식일)
    final patternFns = [_day0, _day1, _day2, _day3, _day4, _day5, _dayRest];
    final dayDataList = List.generate(180, (i) => patternFns[i % 7](dates[i]));

    var batch = _db.batch();
    int opCount = 0;

    for (final day in dayDataList) {
      final date = day['date'] as String;

      for (final s in day['sessions'] as List<Map<String, dynamic>>) {
        batch.set(userRef.collection('focus_sessions').doc(), s);
        opCount++;
        if (opCount >= 490) {
          await batch.commit();
          batch = _db.batch();
          opCount = 0;
        }
      }

      for (final t in day['todos'] as List<Map<String, dynamic>>) {
        batch.set(userRef.collection('todos').doc(), t);
        opCount++;
        if (opCount >= 490) {
          await batch.commit();
          batch = _db.batch();
          opCount = 0;
        }
      }

      final aggRef = userRef
          .collection('stats')
          .doc('aggregations')
          .collection('daily')
          .doc(date);
      batch.set(aggRef, day['aggregation'] as Map<String, dynamic>);
      opCount++;
      if (opCount >= 490) {
        await batch.commit();
        batch = _db.batch();
        opCount = 0;
      }
    }

    batch.set(userRef, {'analysis_started_date': _dateStr(dates.first)},
        SetOptions(merge: true));
    await batch.commit();

    for (final day in dayDataList) {
      final date = day['date'] as String;
      await userRef.collection('analysis').doc(date).set({
        'type': 'daily',
        ...(day['analysis_daily'] as Map<String, dynamic>),
      });
    }
  }

  /// 오늘 기준 30일치 더미 데이터를 Firestore에 씀 (6가지 패턴 순환).
  Future<void> seedOneMonth() async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) throw Exception('로그인 필요');

    final userRef = _db.collection('users').doc(uid);
    final today = DateTime.now();
    final dates = List.generate(30, (i) => today.subtract(Duration(days: 29 - i)));

    // 6가지 패턴 순환
    final patternFns = [_day0, _day1, _day2, _day3, _day4, _day5];
    final dayDataList = List.generate(30, (i) => patternFns[i % 6](dates[i]));

    var batch = _db.batch();
    int opCount = 0;

    for (final day in dayDataList) {
      final date = day['date'] as String;

      for (final s in day['sessions'] as List<Map<String, dynamic>>) {
        batch.set(userRef.collection('focus_sessions').doc(), s);
        opCount++;
        if (opCount >= 490) {
          await batch.commit();
          batch = _db.batch();
          opCount = 0;
        }
      }

      for (final t in day['todos'] as List<Map<String, dynamic>>) {
        batch.set(userRef.collection('todos').doc(), t);
        opCount++;
        if (opCount >= 490) {
          await batch.commit();
          batch = _db.batch();
          opCount = 0;
        }
      }

      final aggRef = userRef
          .collection('stats')
          .doc('aggregations')
          .collection('daily')
          .doc(date);
      batch.set(aggRef, day['aggregation'] as Map<String, dynamic>);
      opCount++;
    }

    batch.set(userRef, {'analysis_started_date': _dateStr(dates.first)},
        SetOptions(merge: true));
    await batch.commit();

    for (final day in dayDataList) {
      final date = day['date'] as String;
      await userRef.collection('analysis').doc(date).set({
        'type': 'daily',
        ...(day['analysis_daily'] as Map<String, dynamic>),
      });
    }
  }

  // ────────────────────────────────────────────────────────────
  // 날짜별 시드 데이터
  // ────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _buildDaySeeds(List<DateTime> dates) {
    return [
      _day0(dates[0]), // 6일 전: 집중 잘 된 날
      _day1(dates[1]), // 5일 전: 무난한 날
      _day2(dates[2]), // 4일 전: 집중 안 된 날
      _day3(dates[3]), // 3일 전: 스톱워치 위주
      _day4(dates[4]), // 2일 전: 보통
      _day5(dates[5]), // 어제: 가벼운 날
      _day6(dates[6]), // 오늘: partial
    ];
  }

  // ── 6일 전: 집중 잘 된 날 ────────────────────────────────────
  Map<String, dynamic> _day0(DateTime d) {
    final date = _dateStr(d);
    return {
      'date': date,
      'sessions': [
        _pomodoro(date, '07:00', '07:25', 25, 25, status: 'completed'),
        _pomodoro(date, '09:00', '09:48', 50, 48,
            status: 'completed',
            phone: [_event(date, '09:40', '09:43', 3)]),
        _stopwatch(date, '14:00', '15:05', 60),
      ],
      'todos': [
        _todo(date, '영어 단어 암기', 'cat_01', isDone: true),
        _todo(date, '수학 문제 풀기', 'cat_02', isDone: true),
        _todo(date, '독서 30분', 'cat_03', isDone: false),
      ],
      'aggregation': {
        'pomodoro_count': 2, 'pomodoro_duration': 73,
        'stopwatch_count': 1, 'stopwatch_duration': 60,
        'drowsy_count': 0, 'drowsy_duration': 0,
        'phone_count': 1, 'phone_duration': 3,
        'todo_total': 3, 'todo_done': 2,
        'time_slots': {
          'dawn':      {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
          'morning':   {'focus_duration': 73, 'drowsy_count': 0, 'phone_count': 1},
          'afternoon': {'focus_duration': 60, 'drowsy_count': 0, 'phone_count': 0},
          'night':     {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
        },
      },
      'analysis_daily': {
        'advice': '오늘 집중 세션 3회 모두 높은 집중률을 보였어요. 오전 시간대가 특히 효율적이에요. 내일도 7~9시 세션을 유지해보세요.',
        'generated_at': '${date}T23:00:00Z',
      },
    };
  }

  // ── 5일 전: 무난한 날 ────────────────────────────────────────
  Map<String, dynamic> _day1(DateTime d) {
    final date = _dateStr(d);
    return {
      'date': date,
      'sessions': [
        _pomodoro(date, '10:00', '10:25', 25, 25, status: 'completed'),
        _pomodoro(date, '13:00', '13:47', 50, 47,
            status: 'incomplete',
            drowsy: [_event(date, '13:35', '13:40', 5)]),
        _pomodoro(date, '16:00', '16:25', 25, 25, status: 'completed'),
      ],
      'todos': [
        _todo(date, '영어 듣기 연습', 'cat_01', isDone: true),
        _todo(date, '수학 오답 노트', 'cat_02', isDone: true),
        _todo(date, '운동 루틴', 'cat_03', isDone: true),
        _todo(date, '과학 요약 정리', 'cat_02', isDone: false),
      ],
      'aggregation': {
        'pomodoro_count': 3, 'pomodoro_duration': 97,
        'stopwatch_count': 0, 'stopwatch_duration': 0,
        'drowsy_count': 1, 'drowsy_duration': 5,
        'phone_count': 0, 'phone_duration': 0,
        'todo_total': 4, 'todo_done': 3,
        'time_slots': {
          'dawn':      {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
          'morning':   {'focus_duration': 25, 'drowsy_count': 0, 'phone_count': 0},
          'afternoon': {'focus_duration': 72, 'drowsy_count': 1, 'phone_count': 0},
          'night':     {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
        },
      },
      'analysis_daily': {
        'advice': '오후 1시대에 졸음 감지가 있었어요. 점심 식사 후 졸음이 오는 패턴이 보여요. 오후 세션 전 10분 정도 가벼운 스트레칭을 권장해요.',
        'generated_at': '${date}T23:00:00Z',
      },
    };
  }

  // ── 4일 전: 집중 안 된 날 ────────────────────────────────────
  Map<String, dynamic> _day2(DateTime d) {
    final date = _dateStr(d);
    return {
      'date': date,
      'sessions': [
        _pomodoro(date, '15:00', '15:18', 25, 18,
            status: 'incomplete',
            drowsy: [_event(date, '15:10', '15:16', 6)],
            phone: [_event(date, '15:05', '15:08', 3)]),
        _pomodoro(date, '17:00', '17:12', 25, 12,
            status: 'incomplete',
            phone: [
              _event(date, '17:03', '17:07', 4),
              _event(date, '17:09', '17:12', 3),
            ]),
      ],
      'todos': [
        _todo(date, '영어 작문', 'cat_01', isDone: false),
        _todo(date, '수학 시험 준비', 'cat_02', isDone: false),
        _todo(date, '산책', 'cat_03', isDone: true),
      ],
      'aggregation': {
        'pomodoro_count': 2, 'pomodoro_duration': 30,
        'stopwatch_count': 0, 'stopwatch_duration': 0,
        'drowsy_count': 1, 'drowsy_duration': 6,
        'phone_count': 3, 'phone_duration': 10,
        'todo_total': 3, 'todo_done': 1,
        'time_slots': {
          'dawn':      {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
          'morning':   {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
          'afternoon': {'focus_duration': 30, 'drowsy_count': 1, 'phone_count': 3},
          'night':     {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
        },
      },
      'analysis_daily': {
        'advice': '오늘은 집중이 쉽지 않은 날이었어요. 폰 감지가 3회, 졸음 감지 1회가 있었어요. 오후 시간대에 집중이 어렵다면 오전이나 저녁으로 세션을 옮겨보는 것을 추천해요.',
        'generated_at': '${date}T23:00:00Z',
      },
    };
  }

  // ── 3일 전: 스톱워치 위주 ─────────────────────────────────────
  Map<String, dynamic> _day3(DateTime d) {
    final date = _dateStr(d);
    return {
      'date': date,
      'sessions': [
        _stopwatch(date, '08:00', '09:30', 85),
        _pomodoro(date, '11:00', '11:25', 25, 25, status: 'completed'),
        _stopwatch(date, '20:00', '20:50', 48),
      ],
      'todos': [
        _todo(date, '영어 독해', 'cat_01', isDone: true),
        _todo(date, '수학 공식 암기', 'cat_02', isDone: true),
        _todo(date, '운동 1시간', 'cat_03', isDone: true),
      ],
      'aggregation': {
        'pomodoro_count': 1, 'pomodoro_duration': 25,
        'stopwatch_count': 2, 'stopwatch_duration': 133,
        'drowsy_count': 0, 'drowsy_duration': 0,
        'phone_count': 0, 'phone_duration': 0,
        'todo_total': 3, 'todo_done': 3,
        'time_slots': {
          'dawn':      {'focus_duration': 0,   'drowsy_count': 0, 'phone_count': 0},
          'morning':   {'focus_duration': 110, 'drowsy_count': 0, 'phone_count': 0},
          'afternoon': {'focus_duration': 0,   'drowsy_count': 0, 'phone_count': 0},
          'night':     {'focus_duration': 48,  'drowsy_count': 0, 'phone_count': 0},
        },
      },
      'analysis_daily': {
        'advice': '오늘 총 158분 집중했어요. 스톱워치를 통한 장시간 집중이 효과적이었어요. 오전 8시대 집중률이 가장 높았어요.',
        'generated_at': '${date}T23:00:00Z',
      },
    };
  }

  // ── 2일 전: 보통 ─────────────────────────────────────────────
  Map<String, dynamic> _day4(DateTime d) {
    final date = _dateStr(d);
    return {
      'date': date,
      'sessions': [
        _pomodoro(date, '09:30', '10:18', 50, 48, status: 'completed'),
        _pomodoro(date, '14:00', '14:43', 50, 43,
            status: 'incomplete',
            drowsy: [_event(date, '14:30', '14:35', 5)],
            phone: [_event(date, '14:38', '14:41', 3)]),
      ],
      'todos': [
        _todo(date, '영어 단어 50개', 'cat_01', isDone: true),
        _todo(date, '수학 풀기', 'cat_02', isDone: false),
        _todo(date, '저녁 운동', 'cat_03', isDone: true),
        _todo(date, '과학 실험 보고서', 'cat_02', isDone: false),
      ],
      'aggregation': {
        'pomodoro_count': 2, 'pomodoro_duration': 91,
        'stopwatch_count': 0, 'stopwatch_duration': 0,
        'drowsy_count': 1, 'drowsy_duration': 5,
        'phone_count': 1, 'phone_duration': 3,
        'todo_total': 4, 'todo_done': 2,
        'time_slots': {
          'dawn':      {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
          'morning':   {'focus_duration': 48, 'drowsy_count': 0, 'phone_count': 0},
          'afternoon': {'focus_duration': 43, 'drowsy_count': 1, 'phone_count': 1},
          'night':     {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
        },
      },
      'analysis_daily': {
        'advice': '오후 2시대에 졸음과 폰 사용이 동시에 나타났어요. 이 시간대에 짧은 휴식 후 다시 집중하는 루틴을 만들어보세요.',
        'generated_at': '${date}T23:00:00Z',
      },
    };
  }

  // ── 어제: 가벼운 날 ──────────────────────────────────────────
  Map<String, dynamic> _day5(DateTime d) {
    final date = _dateStr(d);
    return {
      'date': date,
      'sessions': [
        _stopwatch(date, '10:00', '10:45', 42),
      ],
      'todos': [
        _todo(date, '독서', 'cat_03', isDone: true),
        _todo(date, '영어 복습', 'cat_01', isDone: true),
      ],
      'aggregation': {
        'pomodoro_count': 0, 'pomodoro_duration': 0,
        'stopwatch_count': 1, 'stopwatch_duration': 42,
        'drowsy_count': 0, 'drowsy_duration': 0,
        'phone_count': 0, 'phone_duration': 0,
        'todo_total': 2, 'todo_done': 2,
        'time_slots': {
          'dawn':      {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
          'morning':   {'focus_duration': 42, 'drowsy_count': 0, 'phone_count': 0},
          'afternoon': {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
          'night':     {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
        },
      },
      'analysis_daily': {
        'advice': '가벼운 집중 세션으로 여유롭게 공부했어요. 방해 요소 없이 깔끔하게 마무리한 하루예요.',
        'generated_at': '${date}T23:00:00Z',
      },
    };
  }

  // ── 휴식일: 세션 없음 ─────────────────────────────────────────
  Map<String, dynamic> _dayRest(DateTime d) {
    final date = _dateStr(d);
    return {
      'date': date,
      'sessions': <Map<String, dynamic>>[],
      'todos': [
        _todo(date, '휴식 및 재충전', 'cat_03', isDone: true),
      ],
      'aggregation': {
        'pomodoro_count': 0, 'pomodoro_duration': 0,
        'stopwatch_count': 0, 'stopwatch_duration': 0,
        'drowsy_count': 0, 'drowsy_duration': 0,
        'phone_count': 0, 'phone_duration': 0,
        'todo_total': 1, 'todo_done': 1,
        'time_slots': {
          'dawn':      {'focus_duration': 0, 'drowsy_count': 0, 'phone_count': 0},
          'morning':   {'focus_duration': 0, 'drowsy_count': 0, 'phone_count': 0},
          'afternoon': {'focus_duration': 0, 'drowsy_count': 0, 'phone_count': 0},
          'night':     {'focus_duration': 0, 'drowsy_count': 0, 'phone_count': 0},
        },
      },
      'analysis_daily': {
        'advice': '오늘은 충분한 휴식을 취했어요. 내일 더 활기차게 집중해봐요!',
        'generated_at': '${date}T23:00:00Z',
      },
    };
  }

  // ── 오늘: partial ────────────────────────────────────────────
  Map<String, dynamic> _day6(DateTime d) {
    final date = _dateStr(d);
    return {
      'date': date,
      'sessions': [
        _pomodoro(date, '08:00', '08:25', 25, 25, status: 'completed'),
        _pomodoro(date, '10:00', '10:48', 50, 48,
            status: 'completed',
            phone: [_event(date, '10:40', '10:43', 3)]),
      ],
      'todos': [
        _todo(date, '오늘 할 일 정리', 'cat_01', isDone: true),
        _todo(date, '수학 예습', 'cat_02', isDone: false),
      ],
      'aggregation': {
        'pomodoro_count': 2, 'pomodoro_duration': 73,
        'stopwatch_count': 0, 'stopwatch_duration': 0,
        'drowsy_count': 0, 'drowsy_duration': 0,
        'phone_count': 1, 'phone_duration': 3,
        'todo_total': 2, 'todo_done': 1,
        'time_slots': {
          'dawn':      {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
          'morning':   {'focus_duration': 73, 'drowsy_count': 0, 'phone_count': 1},
          'afternoon': {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
          'night':     {'focus_duration': 0,  'drowsy_count': 0, 'phone_count': 0},
        },
      },
      'analysis_daily': {
        'advice': '오전 집중 세션 2회 완료했어요. 오늘도 좋은 출발이에요!',
        'generated_at': '${date}T23:00:00Z',
      },
    };
  }

  // ────────────────────────────────────────────────────────────
  // 헬퍼
  // ────────────────────────────────────────────────────────────

  Map<String, dynamic> _pomodoro(
    String date,
    String startTime,
    String endTime,
    int planned,
    int actual, {
    required String status,
    List<Map<String, dynamic>> drowsy = const [],
    List<Map<String, dynamic>> phone = const [],
  }) =>
      {
        'type': 'pomodoro',
        'status': status,
        'title': '뽀모도로',
        'start_date': date,
        'start_time': startTime,
        'end_date': date,
        'end_time': endTime,
        'planned_duration': planned,
        'actual_duration': actual,
        'drowsy_events': drowsy,
        'phone_events': phone,
      };

  Map<String, dynamic> _stopwatch(
    String date,
    String startTime,
    String endTime,
    int actual, {
    List<Map<String, dynamic>> pauses = const [],
  }) =>
      {
        'type': 'stopwatch',
        'status': 'completed',
        'title': '스톱워치',
        'start_date': date,
        'start_time': startTime,
        'end_date': date,
        'end_time': endTime,
        'actual_duration': actual,
        'pause_events': pauses,
        'total_pause_duration': 0,
      };

  Map<String, dynamic> _event(
    String date,
    String startTime,
    String endTime,
    int duration,
  ) =>
      {
        'start_date': date,
        'start_time': startTime,
        'end_date': date,
        'end_time': endTime,
        'total_duration': duration,
      };

  Map<String, dynamic> _todo(
    String date,
    String content,
    String categoryId, {
    required bool isDone,
  }) =>
      {
        'content': content,
        'category_id': categoryId,
        'date': date,
        'start_time': null,
        'end_time': null,
        'notify': false,
        'deadline_time': null,
        'notify_before': null,
        'is_done': isDone,
      };

}
