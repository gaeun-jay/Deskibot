// lib/services/timer_service.dart
//
// RealtimeDB (신호용, 덮어쓰기)
//   users/{uid}/status/current_state
//     session_id, type, state, duration,
//     is_detecting_drowsy, is_detecting_phone
//
// Firestore (영구 기록)
//   users/{uid}/focus_sessions/{sessionId}
//     [뽀모도로] type, title, date, start_date, start_time,
//               end_date, end_time, planned_duration, actual_duration,
//               drowsy_events[], phone_events[]
//     [스톱워치] type, title, date, start_date, start_time,
//               end_date, end_time, actual_duration,
//               pause_events[], total_pause_duration
//
//   users/{uid}/stats/drowsy_logs/{date}
//     date, daily_count, daily_duration, events[]
//
//   users/{uid}/stats/phone_logs/{date}
//     date, daily_count, daily_duration, events[]
//
//   users/{uid}/stats/aggregations/{daily|weekly|monthly|yearly}/{key}
//     pomodoro_count, pomodoro_duration,
//     stopwatch_count, stopwatch_duration,
//     drowsy_count, drowsy_duration,
//     phone_count, phone_duration

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:uuid/uuid.dart';

import '../models/timer_state.dart';

class TimerService {
  final String uid;
  final FirebaseFirestore _fs = FirebaseFirestore.instance;
  final FirebaseDatabase _rtdb = FirebaseDatabase.instance;

  TimerService({required this.uid});

  // ── RealtimeDB 경로 ───────────────────────────────────────
  DatabaseReference get _currentStateRef =>
      _rtdb.ref('users/$uid/status/current_state');

  // ── Firestore 경로 ────────────────────────────────────────
  CollectionReference get _focusSessions =>
      _fs.collection('users').doc(uid).collection('focus_sessions');

  DocumentReference _aggRef(String unit, String key) => _fs
      .collection('users')
      .doc(uid)
      .collection('stats')
      .doc('aggregations')
      .collection(unit)
      .doc(key);

  // ══════════════════════════════════════════════════════════
  // POMODORO
  // ══════════════════════════════════════════════════════════

  Future<String> startPomodoro(int durationMin) async {
    final sessionId = const Uuid().v4();
    final now = DateTime.now();

    await Future.wait([
      _currentStateRef.set({
        'session_id': sessionId,
        'type': 'pomodoro',
        'state': 'start',
        'duration': durationMin,
        'started_at': now.toIso8601String(),
        'is_detecting_drowsy': false,
        'is_detecting_phone': false,
      }),
      _focusSessions.doc(sessionId).set({
        'type': 'pomodoro',
        'title': '뽀모도로',
        'date': _dateStr(now),
        'start_date': _dateStr(now),
        'start_time': _timeStr(now),
        'end_date': null,
        'end_time': null,
        'planned_duration': durationMin,
        'actual_duration': null,
        'drowsy_events': [],
        'phone_events': [],
        'status': 'in_progress',
      }),
    ]);

    return sessionId;
  }

  Future<void> endPomodoro(PomodoroState state) async {
    final now = DateTime.now();
    final actualDuration = ((state.durationMin * 60 - state.remainingSec) / 60).round();

    await Future.wait([
      _currentStateRef.set({
        'session_id': '',
        'type': 'pomodoro',
        'state': 'end',
        'duration': null,
        'is_detecting_drowsy': false,
        'is_detecting_phone': false,
      }),
      _focusSessions.doc(state.sessionId).update({
        'end_date': _dateStr(now),
        'end_time': _timeStr(now),
        'actual_duration': actualDuration,
        'drowsy_events': state.drowsyEvents.map((e) => e.toMap()).toList(),
        'phone_events': state.phoneEvents.map((e) => e.toMap()).toList(),
        'status': 'completed',
      }),
    ]);

    await _upsertAggregations(
      date: state.date,
      pomodoroCount: 1,
      pomodoroDuration: actualDuration,
      drowsyCount: state.drowsyEvents.length,
      drowsyDuration: state.drowsyEvents.fold(0, (s, e) => s + e.totalDuration),
      phoneCount: state.phoneEvents.length,
      phoneDuration: state.phoneEvents.fold(0, (s, e) => s + e.totalDuration),
    );
  }

  // ══════════════════════════════════════════════════════════
  // STOPWATCH
  // ══════════════════════════════════════════════════════════

  /// 이미 세션 실행 중인지 확인 (충돌 방지)
  Future<bool> isSessionRunning() async {
    final snap = await _currentStateRef.get();
    if (!snap.exists) return false;
    final data = Map<String, dynamic>.from(snap.value as Map);
    final state = data['state'] as String?;
    return state == 'start' || state == 'resume' || state == 'pause';
  }

  /// 스톱워치 시작
  /// 이미 실행 중이면 null 반환
  Future<String?> startStopwatch() async {
    final running = await isSessionRunning();
    if (running) return null;

    final sessionId = const Uuid().v4();
    final now = DateTime.now();

    await Future.wait([
      _currentStateRef.set({
        'session_id': sessionId,
        'type': 'stopwatch',
        'state': 'start',
        'duration': null,
        'started_at': now.toIso8601String(),
        'is_detecting_drowsy': false,
        'is_detecting_phone': false,
      }),
      _focusSessions.doc(sessionId).set({
        'type': 'stopwatch',
        'title': '스톱워치',
        'date': _dateStr(now),
        'start_date': _dateStr(now),
        'start_time': _timeStr(now),
        'end_date': null,
        'end_time': null,
        'actual_duration': null,
        'pause_events': [],
        'total_pause_duration': 0,
        'status': 'in_progress',
      }),
    ]);

    return sessionId;
  }

  Future<void> pauseStopwatch() async {
    await _currentStateRef.update({
      'state': 'pause',
      'paused_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> resumeStopwatch(int pausedSec) async {
    await _currentStateRef.update({
      'state': 'resume',
      'paused_at': null,
      'total_pause_sec': ServerValue.increment(pausedSec),
    });
  }

  Future<void> endStopwatch(StopwatchState sw) async {
    final now = DateTime.now();
    final actualDuration = (sw.elapsedSec / 60).round();

    await Future.wait([
      _currentStateRef.set({
        'session_id': '',
        'type': 'stopwatch',
        'state': 'end',
        'duration': null,
        'is_detecting_drowsy': false,
        'is_detecting_phone': false,
      }),
      _focusSessions.doc(sw.sessionId).update({
        'end_date': _dateStr(now),
        'end_time': _timeStr(now),
        'actual_duration': actualDuration,
        'pause_events': sw.pauseEvents.map((e) => e.toMap()).toList(),
        'total_pause_duration': sw.totalPauseDuration,
        'status': 'completed',
      }),
    ]);

    await _upsertAggregations(
      date: sw.date,
      stopwatchCount: 1,
      stopwatchDuration: actualDuration,
    );
  }

  Future<void> resetStopwatch() async {
    await _currentStateRef.set({
      'session_id': '',
      'type': 'stopwatch',
      'state': 'end',
      'duration': null,
      'is_detecting_drowsy': false,
      'is_detecting_phone': false,
    });
  }

  // ══════════════════════════════════════════════════════════
  // ESP32 세션 감지 시 Firestore 문서 선생성
  // ══════════════════════════════════════════════════════════
  Future<void> createPomodoroDoc({
    required String sessionId,
    required int durationMin,
    required DateTime startedAt,
  }) async {
    await _focusSessions.doc(sessionId).set({
      'type': 'pomodoro',
      'title': '뽀모도로',
      'date': _dateStr(startedAt),
      'start_date': _dateStr(startedAt),
      'start_time': _timeStr(startedAt),
      'end_date': null,
      'end_time': null,
      'planned_duration': durationMin,
      'actual_duration': null,
      'drowsy_events': [],
      'phone_events': [],
      'status': 'in_progress',
    });
  }

  Future<void> createStopwatchDoc({
    required String sessionId,
    required DateTime startedAt,
  }) async {
    await _focusSessions.doc(sessionId).set({
      'type': 'stopwatch',
      'title': '스톱워치',
      'date': _dateStr(startedAt),
      'start_date': _dateStr(startedAt),
      'start_time': _timeStr(startedAt),
      'end_date': null,
      'end_time': null,
      'actual_duration': null,
      'pause_events': [],
      'total_pause_duration': 0,
      'status': 'in_progress',
    });
  }

  // ══════════════════════════════════════════════════════════
  // current_state listen
  // ══════════════════════════════════════════════════════════
  Stream<Map<String, dynamic>?> listenCurrentState() {
    return _currentStateRef.onValue.map((event) {
      if (!event.snapshot.exists) return null;
      return Map<String, dynamic>.from(event.snapshot.value as Map);
    });
  }

  // ══════════════════════════════════════════════════════════
  // 앱 없이 ESP32만 쓰다가 나중에 앱 켜진 경우 복구
  // ══════════════════════════════════════════════════════════
  Future<void> recoverUnsavedSession() async {
    final snap = await _currentStateRef.get();
    if (!snap.exists) return;

    final data = Map<String, dynamic>.from(snap.value as Map);
    final state = data['state'] as String?;
    final sessionId = data['session_id'] as String? ?? '';
    final type = data['type'] as String?;

    if (state != 'end' || sessionId.isEmpty || type == null) return;

    final existing = await _focusSessions.doc(sessionId).get();
    if (existing.exists) return;

    // Firestore에 없으면 복구 저장 (최소 필드만)
    await _focusSessions.doc(sessionId).set({
      'type': type,
      'title': type == 'stopwatch' ? '스톱워치' : '뽀모도로',
      'date': '',
      'start_date': '',
      'start_time': '',
      'end_date': '',
      'end_time': '',
      if (type == 'pomodoro') ...{
        'planned_duration': data['duration'],
        'actual_duration': 0,
        'drowsy_events': [],
        'phone_events': [],
      },
      if (type == 'stopwatch') ...{
        'actual_duration': 0,
        'pause_events': [],
        'total_pause_duration': 0,
      },
    });
  }

  // ══════════════════════════════════════════════════════════
  // stats/aggregations upsert
  // ══════════════════════════════════════════════════════════
  Future<void> _upsertAggregations({
    required String date,
    int pomodoroCount = 0,
    int pomodoroDuration = 0,
    int stopwatchCount = 0,
    int stopwatchDuration = 0,
    int drowsyCount = 0,
    int drowsyDuration = 0,
    int phoneCount = 0,
    int phoneDuration = 0,
  }) async {
    final delta = {
      'pomodoro_count': FieldValue.increment(pomodoroCount),
      'pomodoro_duration': FieldValue.increment(pomodoroDuration),
      'stopwatch_count': FieldValue.increment(stopwatchCount),
      'stopwatch_duration': FieldValue.increment(stopwatchDuration),
      'drowsy_count': FieldValue.increment(drowsyCount),
      'drowsy_duration': FieldValue.increment(drowsyDuration),
      'phone_count': FieldValue.increment(phoneCount),
      'phone_duration': FieldValue.increment(phoneDuration),
    };

    final week = _isoWeek(date);
    final month = date.substring(0, 7); // "YYYY-MM"
    final year = date.substring(0, 4); // "YYYY"

    await Future.wait([
      _aggRef('daily', date).set(delta, SetOptions(merge: true)),
      _aggRef('weekly', week).set(delta, SetOptions(merge: true)),
      _aggRef('monthly', month).set(delta, SetOptions(merge: true)),
      _aggRef('yearly', year).set(delta, SetOptions(merge: true)),
    ]);
  }

  // ══════════════════════════════════════════════════════════
  // 유틸
  // ══════════════════════════════════════════════════════════
  String _dateStr(DateTime dt) =>
      '${dt.year}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  String _timeStr(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  String _isoWeek(String dateStr) {
    final dt = DateTime.parse(dateStr);
    final jan4 = DateTime(dt.year, 1, 4);
    final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
    final weekNum = dt.difference(week1Monday).inDays ~/ 7 + 1;
    return '${dt.year}-W${weekNum.toString().padLeft(2, '0')}';
  }
}
