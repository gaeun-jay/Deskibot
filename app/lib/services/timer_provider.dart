// lib/services/timer_provider.dart

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

import '../models/timer_state.dart';
import '../services/timer_service.dart';

class TimerProvider extends ChangeNotifier with WidgetsBindingObserver {
  final TimerService _service;

  TimerProvider({required TimerService service}) : _service = service {
    WidgetsBinding.instance.addObserver(this);
    _listenCurrentState();
    _service.recoverUnsavedSession();
  }

  // ── 상태 ──────────────────────────────────────────────────
  PomodoroState _pomodoro = const PomodoroState();
  StopwatchState _stopwatch = const StopwatchState();

  PomodoroState get pomodoro => _pomodoro;
  StopwatchState get stopwatch => _stopwatch;

  bool _pomodoroStartedByApp = false;
  bool _stopwatchStartedByApp = false;
  bool get isStopwatchStartedByApp => _stopwatchStartedByApp;

  Timer? _ticker;
  StreamSubscription? _currentStateSub;
  DateTime? _backgroundEnteredAt;

  // 이전 감지 상태 (on→off 전환 감지용)
  bool _prevDrowsy = false;
  bool _prevPhone = false;

  // 알람 상태
  bool _isAlarming = false;
  bool get isAlarming => _isAlarming;

  final _ringtone = FlutterRingtonePlayer();

  // ══════════════════════════════════════════════════════════
  // current_state listen
  // RealtimeDB 필드: session_id, type, state, duration,
  //                  is_detecting_drowsy, is_detecting_phone
  // ══════════════════════════════════════════════════════════
  void _listenCurrentState() {
    _currentStateSub = _service.listenCurrentState().listen((data) {
      if (data == null) return;

      final state = data['state'] as String?;
      final type = data['type'] as String?;
      final sessionId = data['session_id'] as String? ?? '';
      final duration = data['duration'] as int?;
      final isDrowsy = (data['is_detecting_drowsy'] as bool? ?? false) ||
          (data['drowsy'] as bool? ?? false);
      final isPhone = (data['is_detecting_phone'] as bool? ?? false) ||
          (data['phone'] as bool? ?? false);
      final now = DateTime.now();

      // started_at 역산: Realtime DB에 저장된 실제 시작 시각으로 경과 시간 계산
      final startedAtStr = data['started_at'] as String?;
      final sessionStartedAt = startedAtStr != null
          ? DateTime.tryParse(startedAtStr) ?? now
          : now;
      final totalPauseSec = data['total_pause_sec'] as int? ?? 0;
      final elapsedSec = (now.difference(sessionStartedAt).inSeconds - totalPauseSec)
          .clamp(0, double.infinity).toInt();

      // ── ESP32가 세션 시작한 경우 앱 상태 동기화 ──
      if (state == 'start') {
        if (type == 'pomodoro' &&
            duration != null &&
            _pomodoro.status == TimerStatus.idle &&
            _pomodoro.sessionId != sessionId) {
          final remaining = (duration * 60 - elapsedSec).clamp(0, duration * 60);
          _pomodoro = PomodoroState(
            durationMin: duration,
            remainingSec: remaining,
            status: TimerStatus.running,
            startedAt: sessionStartedAt,
            sessionId: sessionId,
            date: _dateStr(sessionStartedAt),
            startDate: _dateStr(sessionStartedAt),
            startTime: _timeStr(sessionStartedAt),
          );
          // 로봇이 시작한 세션 — HW가 Firestore 전담, 앱은 UI만 동기화
          WakelockPlus.enable();
          _startTicker();
        } else if (type == 'stopwatch' &&
            _stopwatch.status == TimerStatus.idle &&
            !_stopwatchStartedByApp) {
          _stopwatch = StopwatchState(
            elapsedSec: elapsedSec,
            status: TimerStatus.running,
            startedAt: sessionStartedAt,
            sessionId: sessionId,
            date: _dateStr(sessionStartedAt),
            startDate: _dateStr(sessionStartedAt),
            startTime: _timeStr(sessionStartedAt),
          );
          // Firestore 문서가 없을 수 있으므로 선생성 (upsert)
          _service.createStopwatchDoc(
            sessionId: sessionId,
            startedAt: sessionStartedAt,
          );
          _stopwatchStartedByApp = false;
          WakelockPlus.enable();
          _startTicker();
        }
      }

      // ── 앱이 나중에 켜졌을 때 일시정지 상태 동기화 ──
      if (state == 'pause' &&
          type == 'stopwatch' &&
          _stopwatch.status == TimerStatus.idle &&
          !_stopwatchStartedByApp &&
          sessionId.isNotEmpty) {
        final pausedAtStr = data['paused_at'] as String?;
        final pausedAt = pausedAtStr != null
            ? DateTime.tryParse(pausedAtStr) ?? now
            : now;
        final elapsedBeforePause =
            (pausedAt.difference(sessionStartedAt).inSeconds - totalPauseSec)
                .clamp(0, double.infinity)
                .toInt();
        _stopwatch = StopwatchState(
          elapsedSec: elapsedBeforePause,
          status: TimerStatus.paused,
          pausedAt: pausedAt,
          startedAt: sessionStartedAt,
          sessionId: sessionId,
          date: _dateStr(sessionStartedAt),
          startDate: _dateStr(sessionStartedAt),
          startTime: _timeStr(sessionStartedAt),
        );
        _service.createStopwatchDoc(
          sessionId: sessionId,
          startedAt: sessionStartedAt,
        );
      }

      // ── ESP32가 실행 중 스톱워치 정지 ──
      if (state == 'pause' &&
          type == 'stopwatch' &&
          _stopwatch.status == TimerStatus.running) {
        final pausedAtStr = data['paused_at'] as String?;
        final pausedAt = pausedAtStr != null
            ? DateTime.tryParse(pausedAtStr) ?? now
            : now;
        _ticker?.cancel();
        _stopwatch = _stopwatch.copyWith(
          status: TimerStatus.paused,
          pausedAt: pausedAt,
        );
        WakelockPlus.disable();
      }

      // ── ESP32가 스톱워치 재개 ──
      if (state == 'resume' &&
          type == 'stopwatch' &&
          _stopwatch.status == TimerStatus.paused) {
        final pausedAt = _stopwatch.pausedAt ?? now;
        final pauseMin = now.difference(pausedAt).inMinutes;
        final pauseMs = now.difference(pausedAt).inMilliseconds;
        final pauseEvent = PauseEvent(
          pausedAtDate: _dateStr(pausedAt),
          pausedAtTime: _timeStr(pausedAt),
          resumedAtDate: _dateStr(now),
          resumedAtTime: _timeStr(now),
        );
        _stopwatch = _stopwatch.copyWith(
          status: TimerStatus.running,
          totalPauseDuration: _stopwatch.totalPauseDuration + pauseMin,
          totalPauseMs: _stopwatch.totalPauseMs + pauseMs,
          pauseEvents: [..._stopwatch.pauseEvents, pauseEvent],
          clearPausedAt: true,
        );
        // ESP32 resume 시 서버 상태 업데이트
        _service.resumeStopwatch(
            _stopwatch.sessionId, now.difference(pausedAt).inSeconds);
        WakelockPlus.enable();
        _startTicker();
      }

      // ── ESP32가 세션 종료한 경우 ──
      // type을 유지하므로 type으로 뽀모도로/스톱워치 구분
      // sessionId가 비어있고 state가 'end'면 종료 신호
      if (state == 'end' && sessionId.isEmpty) {
        if (type == 'pomodoro' &&
            _pomodoro.status != TimerStatus.idle &&
            _pomodoro.status != TimerStatus.finished) {
          _finishPomodoro();
        } else if (type == 'stopwatch' &&
            _stopwatch.status != TimerStatus.idle) {
          _finishStopwatch();
        }
      }

      // ── 알람 제어 (뽀모도로 실행 중에만) ──
      if (_pomodoro.status == TimerStatus.running) {
        final wasAlarming = _prevDrowsy || _prevPhone;
        final isNowAlarming = isDrowsy || isPhone;
        if (!wasAlarming && isNowAlarming) {
          _startAlarm();
        } else if (wasAlarming && !isNowAlarming) {
          _stopAlarm();
        }
      }

      _prevDrowsy = isDrowsy;
      _prevPhone = isPhone;

      notifyListeners();
    });
  }

  // ══════════════════════════════════════════════════════════
  // 백그라운드 처리
  // ══════════════════════════════════════════════════════════
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundEnteredAt = DateTime.now();
      _ticker?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      if (_backgroundEnteredAt != null) {
        final gap = DateTime.now().difference(_backgroundEnteredAt!).inSeconds;
        _applyBackgroundGap(gap);
        _backgroundEnteredAt = null;
      }
      _restartTickerIfNeeded();
    }
  }

  void _applyBackgroundGap(int gapSec) {
    if (_pomodoro.status == TimerStatus.running) {
      final remaining = _pomodoro.remainingSec - gapSec;
      if (remaining <= 0) {
        _finishPomodoro();
      } else {
        _pomodoro = _pomodoro.copyWith(remainingSec: remaining);
      }
    }
    if (_stopwatch.status == TimerStatus.running) {
      _stopwatch = _stopwatch.copyWith(
        elapsedSec: _stopwatch.elapsedSec + gapSec,
      );
    }
    notifyListeners();
  }

  void _restartTickerIfNeeded() {
    if (_pomodoro.status == TimerStatus.running ||
        _stopwatch.status == TimerStatus.running) {
      _startTicker();
    }
  }

  // ══════════════════════════════════════════════════════════
  // TICKER
  // ══════════════════════════════════════════════════════════
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  void _onTick() {
    bool changed = false;

    if (_pomodoro.status == TimerStatus.running) {
      final next = _pomodoro.remainingSec - 1;
      if (next <= 0) {
        _finishPomodoro();
      } else {
        _pomodoro = _pomodoro.copyWith(remainingSec: next);
      }
      changed = true;
    }

    if (_stopwatch.status == TimerStatus.running) {
      _stopwatch = _stopwatch.copyWith(elapsedSec: _stopwatch.elapsedSec + 1);
      changed = true;
    }

    if (changed) notifyListeners();
  }

  // ══════════════════════════════════════════════════════════
  // POMODORO 컨트롤
  // ══════════════════════════════════════════════════════════
  Future<void> startPomodoro(int durationMin) async {
    _pomodoroStartedByApp = true;
    final now = DateTime.now();
    final sessionId = await _service.startPomodoro(durationMin);

    _pomodoro = PomodoroState(
      durationMin: durationMin,
      remainingSec: durationMin * 60,
      status: TimerStatus.running,
      startedAt: now,
      sessionId: sessionId,
      date: _dateStr(now),
      startDate: _dateStr(now),
      startTime: _timeStr(now),
    );

    WakelockPlus.enable();
    _startTicker();
    notifyListeners();
  }

  /// 수동 종료 (팝업 확인 후 호출)
  Future<void> forceEndPomodoro() async {
    _ticker?.cancel();
    _stopAlarm();
    if (_pomodoroStartedByApp) {
      await _service.endPomodoro(_pomodoro, isForced: true);
    }
    _pomodoroStartedByApp = false;
    _pomodoro = const PomodoroState();
    WakelockPlus.disable();
    notifyListeners();
  }

  /// 타이머 완료 or ESP32 종료
  void _finishPomodoro() {
    _ticker?.cancel();
    _stopAlarm();
    if (_pomodoroStartedByApp) {
      _service.endPomodoro(_pomodoro, isForced: false);
    }
    _pomodoroStartedByApp = false;
    _pomodoro = _pomodoro.copyWith(
      remainingSec: 0,
      status: TimerStatus.finished,
    );
    WakelockPlus.disable();
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════
  // STOPWATCH 컨트롤
  // ══════════════════════════════════════════════════════════

  /// 앱에서 스톱워치 시작
  /// 이미 실행 중이면 false 반환
  Future<bool> startStopwatch() async {
    // listen보다 먼저 플래그 세팅 (타이밍 이슈 방지)
    _stopwatchStartedByApp = true;

    final sessionId = await _service.startStopwatch();
    if (sessionId == null) {
      _stopwatchStartedByApp = false; // 실패 시 롤백
      return false;
    }

    final now = DateTime.now();
    _stopwatch = StopwatchState(
      status: TimerStatus.running,
      startedAt: now,
      sessionId: sessionId,
      date: _dateStr(now),
      startDate: _dateStr(now),
      startTime: _timeStr(now),
    );

    WakelockPlus.enable();
    _startTicker();
    notifyListeners();
    return true;
  }

  Future<void> pauseStopwatch() async {
    await _service.pauseStopwatch(_stopwatch.sessionId);
    _ticker?.cancel();
    _stopwatch = _stopwatch.copyWith(
      status: TimerStatus.paused,
      pausedAt: DateTime.now(),
    );
    WakelockPlus.disable();
    notifyListeners();
  }

  Future<void> resumeStopwatch() async {
    final now = DateTime.now();
    final pauseSec = _stopwatch.pausedAt != null
        ? now.difference(_stopwatch.pausedAt!).inSeconds
        : 0;
    await _service.resumeStopwatch(_stopwatch.sessionId, pauseSec);

    if (_stopwatch.pausedAt != null) {
      final pausedAt = _stopwatch.pausedAt!;
      final pauseMin = now.difference(pausedAt).inMinutes;
      final pauseMs = now.difference(pausedAt).inMilliseconds;
      final pauseEvent = PauseEvent(
        pausedAtDate: _dateStr(pausedAt),
        pausedAtTime: _timeStr(pausedAt),
        resumedAtDate: _dateStr(now),
        resumedAtTime: _timeStr(now),
      );
      _stopwatch = _stopwatch.copyWith(
        status: TimerStatus.running,
        totalPauseDuration: _stopwatch.totalPauseDuration + pauseMin,
        totalPauseMs: _stopwatch.totalPauseMs + pauseMs,
        pauseEvents: [..._stopwatch.pauseEvents, pauseEvent],
        clearPausedAt: true,
      );
    } else {
      _stopwatch = _stopwatch.copyWith(status: TimerStatus.running);
    }

    WakelockPlus.enable();
    _startTicker();
    notifyListeners();
  }

  void recordLap(int elapsedMs) {
    final lapNumber = _stopwatch.lapRecords.length + 1;
    _stopwatch = _stopwatch.copyWith(
      lapRecords: [
        ..._stopwatch.lapRecords,
        LapRecord(lapNumber: lapNumber, elapsedMs: elapsedMs),
      ],
    );
    notifyListeners();
  }

  Future<void> endStopwatch() async {
    _ticker?.cancel();
    await _service.endStopwatch(_stopwatch);
    _stopwatch = const StopwatchState();
    _stopwatchStartedByApp = false;
    WakelockPlus.disable();
    notifyListeners();
  }

  Future<void> resetStopwatch() async {
    _ticker?.cancel();
    await _service.resetStopwatch();
    _stopwatch = const StopwatchState();
    _stopwatchStartedByApp = false;
    WakelockPlus.disable();
    notifyListeners();
  }

  /// ESP32가 스톱워치 종료한 경우
  void _finishStopwatch() {
    _ticker?.cancel();
    _service.endStopwatch(_stopwatch);
    _stopwatch = const StopwatchState();
    _stopwatchStartedByApp = false;
    WakelockPlus.disable();
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════
  // 유틸
  // ══════════════════════════════════════════════════════════
  String formatSec(int sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _dateStr(DateTime dt) =>
      '${dt.year}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  String _timeStr(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';

  // ══════════════════════════════════════════════════════════
  // 알람
  // ══════════════════════════════════════════════════════════
  void _startAlarm() {
    if (_isAlarming) return;
    _isAlarming = true;
    _ringtone.playAlarm(looping: true);
  }

  void _stopAlarm() {
    if (!_isAlarming) return;
    _isAlarming = false;
    _ringtone.stop();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _currentStateSub?.cancel();
    _stopAlarm();
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    super.dispose();
  }
}
