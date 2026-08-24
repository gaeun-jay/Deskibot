// lib/services/timer_service.dart
//
// Firebase RTDB + Firestore → WebSocket /ws/focus
//
// 타이머 명령 (앱 → 서버):
//   focus_start   { mode, planned_duration_sec?, title }
//   focus_pause   { session_id, revision }
//   focus_resume  { session_id, revision }
//   focus_end     { session_id, revision, outcome }
//
// 서버 → 앱 브로드캐스트:
//   focus_state    { type, action, session:{session_id, mode, status,
//                    runtime_state, planned_duration_sec, started_at,
//                    paused_at, total_pause_duration_sec, revision, ...} }
//   detection_event { action, event:{kind, ...} }
//
// listenCurrentState() 는 기존 RTDB 스트림과 동일한 Map 구조를 반환해
// TimerProvider 변경을 최소화한다.

import 'dart:async';
import '../models/timer_state.dart';
import 'api_client.dart';
import 'focus_websocket_service.dart';

class TimerService {
  final String uid;
  final FocusWebSocketService _ws = FocusWebSocketService.instance;

  // revision: 서버 낙관적 동시성 제어 필드.
  // pause/resume/end 시 현재 revision 을 함께 보내야 한다.
  int _revision = 0;

  // 감지 상태 (detection_event 로 유지)
  bool _isDrowsy = false;
  bool _isPhone = false;

  // 마지막 세션 상태 (detection 이벤트와 합칠 때 사용)
  Map<String, dynamic>? _lastSessionMap;

  TimerService({required this.uid}) {
    _ws.connect();
  }

  // ══════════════════════════════════════════════════════════
  // POMODORO
  // ══════════════════════════════════════════════════════════

  Future<String> startPomodoro(int durationMin) async {
    final res = await _ws.sendAndAwait(
      {
        'type': 'focus_start',
        'mode': 'pomodoro',
        'planned_duration_sec': durationMin * 60,
        'title': '뽀모도로',
      },
      expectedAction: 'focus_start',
    );
    final session = res?['session'] as Map?;
    final sessionId = session?['session_id']?.toString() ?? '';
    _revision = (session?['revision'] as num?)?.toInt() ?? 0;
    return sessionId;
  }

  Future<void> endPomodoro(PomodoroState state, {bool isForced = false}) async {
    if (state.sessionId.isEmpty) return;
    final isCompleted = !isForced && state.remainingSec <= 5;
    await _ws.sendAndAwait(
      {
        'type': 'focus_end',
        'session_id': state.sessionId,
        'revision': _revision,
        'outcome': isCompleted ? 'completed' : 'incomplete',
      },
      expectedAction: 'focus_end',
    );
    _revision = 0;
  }

  // ══════════════════════════════════════════════════════════
  // STOPWATCH
  // ══════════════════════════════════════════════════════════

  Future<bool> isSessionRunning() async {
    // 서버 상태는 WebSocket 스트림이 알려줌 → 로컬 상태로 판단
    return _lastSessionMap != null &&
        _lastSessionMap!['state'] != 'end' &&
        (_lastSessionMap!['session_id'] as String?)?.isNotEmpty == true;
  }

  Future<String?> startStopwatch() async {
    final running = await isSessionRunning();
    if (running) return null;

    final res = await _ws.sendAndAwait(
      {
        'type': 'focus_start',
        'mode': 'stopwatch',
        'title': '스톱워치',
      },
      expectedAction: 'focus_start',
    );
    final session = res?['session'] as Map?;
    final sessionId = session?['session_id']?.toString() ?? '';
    _revision = (session?['revision'] as num?)?.toInt() ?? 0;
    return sessionId.isEmpty ? null : sessionId;
  }

  Future<void> pauseStopwatch(String sessionId) async {
    if (sessionId.isEmpty) return;
    final res = await _ws.sendAndAwait(
      {
        'type': 'focus_pause',
        'session_id': sessionId,
        'revision': _revision,
      },
      expectedAction: 'focus_pause',
    );
    final session = res?['session'] as Map?;
    if (session != null) {
      _revision = (session['revision'] as num?)?.toInt() ?? _revision;
    }
  }

  Future<void> resumeStopwatch(String sessionId, int pausedSec) async {
    if (sessionId.isEmpty) return;
    final res = await _ws.sendAndAwait(
      {
        'type': 'focus_resume',
        'session_id': sessionId,
        'revision': _revision,
      },
      expectedAction: 'focus_resume',
    );
    final session = res?['session'] as Map?;
    if (session != null) {
      _revision = (session['revision'] as num?)?.toInt() ?? _revision;
    }
  }

  Future<void> endStopwatch(StopwatchState sw) async {
    if (sw.sessionId.isEmpty) return;
    await _ws.sendAndAwait(
      {
        'type': 'focus_end',
        'session_id': sw.sessionId,
        'revision': _revision,
        'outcome': 'completed',
      },
      expectedAction: 'focus_end',
    );
    _revision = 0;
  }

  Future<void> resetStopwatch() async {}

  // ══════════════════════════════════════════════════════════
  // ESP32 세션 선생성 — SQL 에서는 서버가 처리
  // ══════════════════════════════════════════════════════════
  Future<void> createPomodoroDoc({
    required String sessionId,
    required int durationMin,
    required DateTime startedAt,
  }) async {}

  Future<void> createStopwatchDoc({
    required String sessionId,
    required DateTime startedAt,
  }) async {}

  // ══════════════════════════════════════════════════════════
  // 상태 스트림
  // WebSocket 이벤트를 구 RTDB 형식으로 변환해 TimerProvider 변경을 최소화
  // ══════════════════════════════════════════════════════════
  Stream<Map<String, dynamic>?> listenCurrentState() {
    return _ws.stream.map((msg) {
      final type = msg['type'] as String?;

      // ── 감지 이벤트 (ESP32 전용 발신) ──
      if (type == 'detection_event') {
        final action = msg['action'] as String?;
        final kind = (msg['event'] as Map?)?['kind'] as String?;
        if (action == 'detection_start') {
          if (kind == 'drowsy') _isDrowsy = true;
          if (kind == 'phone') _isPhone = true;
        } else if (action == 'detection_end') {
          if (kind == 'drowsy') _isDrowsy = false;
          if (kind == 'phone') _isPhone = false;
        }
        // 마지막 세션 맵에 감지 상태만 업데이트해서 반환
        if (_lastSessionMap == null) return null;
        return {
          ..._lastSessionMap!,
          'is_detecting_drowsy': _isDrowsy,
          'drowsy': _isDrowsy,
          'is_detecting_phone': _isPhone,
          'phone': _isPhone,
        };
      }

      // ── 세션 상태 이벤트 ──
      if (type != 'focus_state') return null;

      final session = msg['session'] as Map<String, dynamic>?;

      // session == null → 진행 중인 세션 없음 (end 후 초기화)
      if (session == null) {
        _lastSessionMap = null;
        _revision = 0;
        return {
          'session_id': '',
          'type': '',
          'state': 'end',
          'duration': 0,
          'started_at': '',
          'paused_at': '',
          'total_pause_sec': 0,
          'is_detecting_drowsy': false,
          'is_detecting_phone': false,
          'drowsy': false,
          'phone': false,
        };
      }

      // revision 업데이트
      _revision = (session['revision'] as num?)?.toInt() ?? _revision;

      // status → RTDB state 변환
      final action = msg['action'] as String?;
      final status = session['status'] as String?;
      final runtimeState = session['runtime_state'] as String?;

      final String rtdbState;
      if (status == 'completed' ||
          status == 'incomplete' ||
          status == 'interrupted') {
        rtdbState = 'end';
      } else if (runtimeState == 'paused') {
        rtdbState = 'pause';
      } else if (action == 'focus_resume') {
        // 로봇이 재개한 경우 — runtimeState 는 'running' 이라 'start' 로
        // 잘못 분류되므로 action 으로 명시적으로 구분한다.
        rtdbState = 'resume';
      } else {
        rtdbState = 'start';
      }

      final plannedSec =
          (session['planned_duration_sec'] as num?)?.toInt() ?? 0;
      final totalPauseSec =
          (session['total_pause_duration_sec'] as num?)?.toInt() ?? 0;

      final map = <String, dynamic>{
        'session_id': session['session_id'] ?? '',
        'type': session['mode'] ?? '',       // 'pomodoro' | 'stopwatch'
        'state': rtdbState,
        'duration': plannedSec ~/ 60,        // 초 → 분
        'started_at': session['started_at'] ?? '',
        'paused_at': session['paused_at'] ?? '',
        'total_pause_sec': totalPauseSec,
        'is_detecting_drowsy': _isDrowsy,
        'is_detecting_phone': _isPhone,
        'drowsy': _isDrowsy,
        'phone': _isPhone,
      };

      _lastSessionMap = map;
      return map;
    }).where((m) => m != null).cast<Map<String, dynamic>?>();
  }

  // ══════════════════════════════════════════════════════════
  // 앱 재시작 복구 — WebSocket 연결 시 서버가 자동으로 현재 세션 전송
  // ══════════════════════════════════════════════════════════
  Future<void> recoverUnsavedSession() async {}

  // ══════════════════════════════════════════════════════════
  // 백그라운드 중 누락된 감지 이벤트 서버에서 조회
  // returns: {'drowsy': {'count': N, 'latest_at': '...', 'latest_duration_sec': N},
  //           'phone':  {'count': N, 'latest_at': '...', 'latest_duration_sec': N}}
  // ══════════════════════════════════════════════════════════
  Future<Map<String, dynamic>?> fetchSessionEvents(String sessionId) async {
    if (sessionId.isEmpty) return null;
    try {
      final res = await ApiClient().get('/api/focus-sessions/$sessionId');
      if (res is Map<String, dynamic>) return res;
      return null;
    } catch (_) {
      return null;
    }
  }

}
