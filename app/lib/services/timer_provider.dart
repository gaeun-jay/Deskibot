// lib/services/timer_provider.dart

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

import '../models/focus_session_model.dart';
import '../models/timer_state.dart';
import '../services/focus_session_service.dart';
import '../services/notification_service.dart';
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

  /// 마지막으로 관찰한 뽀모도로 진행 여부. 알림 보류의 기준이다.
  bool _pomodoroActive = false;

  /// 마지막으로 관찰한 집중 세션 진행 여부. 집중 현황 갱신의 기준이다.
  bool _sessionActive = false;

  /// 뽀모도로가 도는 중인지. 실행 중이든 일시정지든 세션이 열려 있으면 참이다.
  ///
  /// 알림 보류는 여기에만 걸린다. 스톱워치 중에는 알림이 와야 한다는 게
  /// 팀 결정이라 아래 [_isSessionActive] 와 기준을 나눠 뒀다.
  bool get _isPomodoroActive =>
      _pomodoro.status == TimerStatus.running ||
      _pomodoro.status == TimerStatus.paused;

  /// 집중 세션이 열려 있는지. 이쪽은 스톱워치도 포함한다 — 스톱워치로 쌓은
  /// 시간도 "오늘의 집중 현황" 에 들어가므로 끝나면 똑같이 다시 불러와야 한다.
  bool get _isSessionActive =>
      _isPomodoroActive ||
      _stopwatch.status == TimerStatus.running ||
      _stopwatch.status == TimerStatus.paused;

  /// 상태가 바뀔 때마다 불린다.
  ///
  /// 세션 시작/종료는 앱에서만 일어나는 게 아니다. ESP32 가 시작시키거나
  /// 자리이탈로 끝나기도 해서, 개별 함수마다 처리를 심으면 빠뜨리는 경로가
  /// 생긴다. 그래서 상태 변화가 흘러가는 길목인 notifyListeners 한 곳에서
  /// 전환만 잡아낸다.
  @override
  void notifyListeners() {
    _syncFocusSideEffects();
    super.notifyListeners();
  }

  /// 두 가지를 각자의 기준으로 따로 본다. 한 덩어리로 묶으면 스톱워치를
  /// 알림 보류에서 빼는 순간 집중 현황 갱신까지 같이 빠진다.
  ///
  /// 실패가 타이머를 망가뜨리면 안 되므로 예외는 삼키고 로그만 남긴다.
  /// 알림이 안 걸리는 것보다 집중 세션이 끊기는 게 더 나쁘다.
  void _syncFocusSideEffects() {
    // ── 알림 보류: 뽀모도로만 ──
    final pomodoroActive = _isPomodoroActive;
    if (pomodoroActive != _pomodoroActive) {
      _pomodoroActive = pomodoroActive;
      if (pomodoroActive) {
        NotificationService.instance.suspend().catchError(
              (e) => debugPrint('[알림] 보류 실패: $e'),
            );
      } else {
        NotificationService.instance.resume().catchError(
              (e) => debugPrint('[알림] 복구 실패: $e'),
            );
      }
    }

    // ── 집중 현황 갱신: 뽀모도로 + 스톱워치 ──
    final sessionActive = _isSessionActive;
    if (sessionActive != _sessionActive) {
      _sessionActive = sessionActive;
      if (!sessionActive) {
        // 세션이 끝났으니 홈의 "오늘의 집중 현황" 을 다시 불러온다.
        // 서버가 focus_end 를 받아 집계를 마칠 틈을 조금 준다 — 곧바로
        // 부르면 방금 끝난 세션이 아직 안 잡힌 예전 값을 그대로 받는다.
        Future.delayed(const Duration(seconds: 2), () {
          FocusSessionService().refresh().catchError(
            (e) {
              debugPrint('[집중현황] 갱신 실패: $e');
              return const <FocusSessionModel>[];
            },
          );
        });
      }
    }
  }

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
            (_pomodoro.status == TimerStatus.idle ||
             _pomodoro.status == TimerStatus.finished) &&
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
        // 로봇이 이미 서버에서 resume 처리했으므로 앱은 서버에 중복 요청하지 않는다.
        WakelockPlus.enable();
        _startTicker();
      }

      // ── ESP32/자리이탈로 세션 종료한 경우 ──
      // session == null → sessionId 빈 문자열 (초기화 신호)
      // session 있음  → sessionId 가 현재 진행 중인 세션과 일치할 때만 종료
      if (state == 'end' &&
          (sessionId.isEmpty ||
           sessionId == _pomodoro.sessionId ||
           sessionId == _stopwatch.sessionId)) {
        if (type == 'pomodoro' &&
            _pomodoro.status != TimerStatus.idle &&
            _pomodoro.status != TimerStatus.finished) {
          _finishPomodoro();
        } else if (type == 'stopwatch' &&
            _stopwatch.status != TimerStatus.idle) {
          _finishStopwatch();
        }
      }

      // ── 알람 제어 + 감지 이벤트 누적 (뽀모도로 실행 중에만) ──
      if (_pomodoro.status == TimerStatus.running) {
        final wasAlarming = _prevDrowsy || _prevPhone;
        final isNowAlarming = isDrowsy || isPhone;
        if (!wasAlarming && isNowAlarming) {
          _startAlarm();
        } else if (wasAlarming && !isNowAlarming) {
          _stopAlarm();
        }

        // 졸음 시작 → drowsyStartedAt 기록 (알림 배너 메시지 구분용)
        if (!_prevDrowsy && isDrowsy) {
          _pomodoro = _pomodoro.copyWith(drowsyStartedAt: now);
        }
        // 졸음 종료 → DrowsyEvent 누적 + startedAt 초기화
        if (_prevDrowsy && !isDrowsy && _pomodoro.drowsyStartedAt != null) {
          final event = DrowsyEvent(
            startDate: _dateStr(_pomodoro.drowsyStartedAt!),
            startTime: _timeStr(_pomodoro.drowsyStartedAt!),
            endDate: _dateStr(now),
            endTime: _timeStr(now),
            totalDuration:
                now.difference(_pomodoro.drowsyStartedAt!).inMinutes,
          );
          _pomodoro = _pomodoro.copyWith(
            drowsyEvents: [..._pomodoro.drowsyEvents, event],
            clearDrowsyStart: true,
          );
        }
        // 폰 시작 → phoneStartedAt 기록
        if (!_prevPhone && isPhone) {
          _pomodoro = _pomodoro.copyWith(phoneStartedAt: now);
        }
        // 폰 종료 → PhoneEvent 누적 + startedAt 초기화
        if (_prevPhone && !isPhone && _pomodoro.phoneStartedAt != null) {
          final event = PhoneEvent(
            startDate: _dateStr(_pomodoro.phoneStartedAt!),
            startTime: _timeStr(_pomodoro.phoneStartedAt!),
            endDate: _dateStr(now),
            endTime: _timeStr(now),
            totalDuration:
                now.difference(_pomodoro.phoneStartedAt!).inMinutes,
          );
          _pomodoro = _pomodoro.copyWith(
            phoneEvents: [..._pomodoro.phoneEvents, event],
            clearPhoneStart: true,
          );
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
    final now = DateTime.now();

    if (_pomodoro.status == TimerStatus.running) {
      // startedAt 기준으로 재계산 → 정수 절삭 오차 누적 방지
      final int remaining;
      if (_pomodoro.startedAt != null) {
        final elapsed = now.difference(_pomodoro.startedAt!).inSeconds;
        remaining = (_pomodoro.durationMin * 60 - elapsed).clamp(0, _pomodoro.durationMin * 60);
      } else {
        remaining = _pomodoro.remainingSec - gapSec;
      }
      if (remaining <= 0) {
        _finishPomodoro();
      } else {
        _pomodoro = _pomodoro.copyWith(remainingSec: remaining);
      }
    }
    if (_stopwatch.status == TimerStatus.running) {
      // startedAt 기준으로 재계산 (totalPauseDuration 반영)
      if (_stopwatch.startedAt != null) {
        final elapsed = now.difference(_stopwatch.startedAt!).inSeconds
            - (_stopwatch.totalPauseMs ~/ 1000);
        _stopwatch = _stopwatch.copyWith(
          elapsedSec: elapsed.clamp(0, double.infinity.toInt()),
        );
      } else {
        _stopwatch = _stopwatch.copyWith(
          elapsedSec: _stopwatch.elapsedSec + gapSec,
        );
      }
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
