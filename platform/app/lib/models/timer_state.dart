// lib/models/timer_state.dart

enum TimerStatus { idle, running, paused, finished }

// ── 졸음 감지 이벤트 ───────────────────────────────────────────
// Firestore focus_sessions.drowsy_events[]
class DrowsyEvent {
  final String startDate;  // "YYYY-MM-DD"
  final String startTime;  // "HH:mm"
  final String endDate;
  final String endTime;
  final int totalDuration; // 분

  const DrowsyEvent({
    required this.startDate,
    required this.startTime,
    required this.endDate,
    required this.endTime,
    required this.totalDuration,
  });

  Map<String, dynamic> toMap() => {
        'start_date': startDate,
        'start_time': startTime,
        'end_date': endDate,
        'end_time': endTime,
        'total_duration': totalDuration,
      };
}

// ── 폰 감지 이벤트 ─────────────────────────────────────────────
// Firestore focus_sessions.phone_events[]
class PhoneEvent {
  final String startDate;
  final String startTime;
  final String endDate;
  final String endTime;
  final int totalDuration;

  const PhoneEvent({
    required this.startDate,
    required this.startTime,
    required this.endDate,
    required this.endTime,
    required this.totalDuration,
  });

  Map<String, dynamic> toMap() => {
        'start_date': startDate,
        'start_time': startTime,
        'end_date': endDate,
        'end_time': endTime,
        'total_duration': totalDuration,
      };
}

// ── 일시정지 이벤트 ────────────────────────────────────────────
// Firestore focus_sessions.pause_events[] (스톱워치 전용)
class PauseEvent {
  final String pausedAtDate;
  final String pausedAtTime;
  final String resumedAtDate;
  final String resumedAtTime;

  const PauseEvent({
    required this.pausedAtDate,
    required this.pausedAtTime,
    required this.resumedAtDate,
    required this.resumedAtTime,
  });

  Map<String, dynamic> toMap() => {
        'paused_at_date': pausedAtDate,
        'paused_at_time': pausedAtTime,
        'resumed_at_date': resumedAtDate,
        'resumed_at_time': resumedAtTime,
      };
}

// ── 뽀모도로 상태 ──────────────────────────────────────────────
// RealtimeDB current_state 필드:
//   session_id, type, state, duration,
//   is_detecting_drowsy, is_detecting_phone
class PomodoroState {
  final int durationMin;    // 25 or 50
  final int remainingSec;
  final TimerStatus status;
  final DateTime? startedAt;
  final String sessionId;
  final String date;        // "YYYY-MM-DD"
  final String startDate;
  final String startTime;   // "HH:mm"

  // 감지 이벤트 누적 (로컬)
  final List<DrowsyEvent> drowsyEvents;
  final List<PhoneEvent> phoneEvents;

  // 현재 진행 중인 감지 시작 시각 (로컬 임시)
  final DateTime? drowsyStartedAt;
  final DateTime? phoneStartedAt;

  const PomodoroState({
    this.durationMin = 25,
    this.remainingSec = 25 * 60,
    this.status = TimerStatus.idle,
    this.startedAt,
    this.sessionId = '',
    this.date = '',
    this.startDate = '',
    this.startTime = '',
    this.drowsyEvents = const [],
    this.phoneEvents = const [],
    this.drowsyStartedAt,
    this.phoneStartedAt,
  });

  PomodoroState copyWith({
    int? durationMin,
    int? remainingSec,
    TimerStatus? status,
    DateTime? startedAt,
    String? sessionId,
    String? date,
    String? startDate,
    String? startTime,
    List<DrowsyEvent>? drowsyEvents,
    List<PhoneEvent>? phoneEvents,
    DateTime? drowsyStartedAt,
    DateTime? phoneStartedAt,
    bool clearDrowsyStart = false,
    bool clearPhoneStart = false,
  }) {
    return PomodoroState(
      durationMin: durationMin ?? this.durationMin,
      remainingSec: remainingSec ?? this.remainingSec,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      sessionId: sessionId ?? this.sessionId,
      date: date ?? this.date,
      startDate: startDate ?? this.startDate,
      startTime: startTime ?? this.startTime,
      drowsyEvents: drowsyEvents ?? this.drowsyEvents,
      phoneEvents: phoneEvents ?? this.phoneEvents,
      drowsyStartedAt:
          clearDrowsyStart ? null : (drowsyStartedAt ?? this.drowsyStartedAt),
      phoneStartedAt:
          clearPhoneStart ? null : (phoneStartedAt ?? this.phoneStartedAt),
    );
  }
}

// ── 스톱워치 상태 ──────────────────────────────────────────────
class StopwatchState {
  final int elapsedSec;
  final int totalPauseDuration; // 분
  final TimerStatus status;
  final DateTime? startedAt;
  final DateTime? pausedAt;
  final String sessionId;
  final String date;
  final String startDate;
  final String startTime;
  final List<PauseEvent> pauseEvents;

  const StopwatchState({
    this.elapsedSec = 0,
    this.totalPauseDuration = 0,
    this.status = TimerStatus.idle,
    this.startedAt,
    this.pausedAt,
    this.sessionId = '',
    this.date = '',
    this.startDate = '',
    this.startTime = '',
    this.pauseEvents = const [],
  });

  StopwatchState copyWith({
    int? elapsedSec,
    int? totalPauseDuration,
    TimerStatus? status,
    DateTime? startedAt,
    DateTime? pausedAt,
    String? sessionId,
    String? date,
    String? startDate,
    String? startTime,
    List<PauseEvent>? pauseEvents,
    bool clearPausedAt = false,
  }) {
    return StopwatchState(
      elapsedSec: elapsedSec ?? this.elapsedSec,
      totalPauseDuration: totalPauseDuration ?? this.totalPauseDuration,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      pausedAt: clearPausedAt ? null : (pausedAt ?? this.pausedAt),
      sessionId: sessionId ?? this.sessionId,
      date: date ?? this.date,
      startDate: startDate ?? this.startDate,
      startTime: startTime ?? this.startTime,
      pauseEvents: pauseEvents ?? this.pauseEvents,
    );
  }
}
