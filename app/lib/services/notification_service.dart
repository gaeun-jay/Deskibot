// lib/services/notification_service.dart
//
// 할 일 마감 알림.
//
// 폰이 직접 띄운다. 알릴 시각이 할 일을 저장하는 시점에 이미 정해지므로
// 서버가 나중에 알려줄 것이 없고, 그래서 푸시(FCM)가 필요 없다. 인터넷이
// 끊겨 있어도, 앱이 꺼져 있어도 뜬다.
//
// 알림을 거는 규칙:
//   미완료 + 마감 시각 있음 + 알림 설정  →  (마감 − 60분 또는 30분)에 예약
//   완료로 체크                          →  취소
//   체크 해제                            →  다시 예약
//   마감·알림 수정                       →  취소 후 재예약
//   삭제                                 →  취소
//   알림 시각이 이미 지났으면            →  예약하지 않음
//   뽀모도로 진행 중                     →  보류, 끝나면 되돌림
//
// 보류는 뽀모도로에만 건다. 스톱워치 중에는 알림이 오는 게 맞다는 게 팀
// 결정이다.
//
// 지난 시각 규칙이 중요하다. 지난 시각으로 예약하면 안드로이드가 즉시 띄우기
// 때문에, 오래된 할 일의 체크를 해제하는 순간 알림이 튀어나온다.

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'package:deskibot/models/todo_model.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;

  /// 집중 세션이 도는 동안 true. 이때는 예약을 새로 걸지 않는다.
  bool _suspended = false;
  bool get isSuspended => _suspended;

  /// 세션 시작 때 걷어낸 예약. 끝나면 이걸로 되돌린다.
  List<PendingNotificationRequest> _held = const [];

  /// 할 일 채널. 안드로이드는 채널 단위로 소리·중요도를 관리한다.
  static const _channel = AndroidNotificationChannel(
    'todo_deadline',
    '할 일 마감 알림',
    description: '마감 시각이 다가온 할 일을 알려줍니다.',
    importance: Importance.high,
  );

  // ── 초기화 ────────────────────────────────────────────────────────

  /// 앱 시작 시 한 번 부른다. 두 번 불러도 안전하다.
  Future<void> init() async {
    if (_ready) return;

    // 예약 시각을 KST 로 계산하기 위한 시간대 데이터. 이걸 빼먹으면
    // 예약이 UTC 로 잡혀 실제보다 9시간 늦게 뜬다.
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Seoul'));

    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    _ready = true;
  }

  /// 알림 권한을 요청한다. Android 13+ 는 동의가 없으면 예약이 성공한 것처럼
  /// 보이지만 아무것도 뜨지 않는다.
  Future<bool> requestPermission() async {
    await init();

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;

    final granted = await android.requestNotificationsPermission() ?? false;
    // 정확한 시각 알람은 별도 권한이다. 거부돼도 알림 자체는 뜨므로
    // 실패를 치명적으로 다루지 않는다 (몇 분 늦게 뜰 수 있다).
    await android.requestExactAlarmsPermission();

    debugPrint('[알림] 권한 ${granted ? "허용" : "거부"}');
    return granted;
  }

  // ── 예약 · 취소 ───────────────────────────────────────────────────

  /// 할 일 하나의 알림을 현재 상태에 맞게 다시 건다.
  /// 기존 예약을 지우고 조건이 맞을 때만 새로 잡으므로, 추가·수정·완료·
  /// 완료 해제 어느 경우에나 이것만 부르면 된다.
  Future<void> sync(TodoModel todo) async {
    await init();
    await cancel(todo.id);

    // 집중 세션 중에는 새로 걸지 않는다. 세션이 끝나면 resume() 이
    // 보류해둔 것과 함께 다시 잡아준다.
    if (_suspended) return;

    final at = _scheduledTimeFor(todo);
    if (at == null) return;

    await _schedule(_idOf(todo.id), '마감이 다가와요', todo.content, at);
    debugPrint('[알림] 예약 "${todo.content}" → $at');
  }

  Future<void> cancel(String todoId) async {
    await init();
    await _plugin.cancel(_idOf(todoId));
  }

  /// 목록 전체를 현재 상태에 맞춘다. 로그인 직후나 서버에서 목록을 새로
  /// 받아온 뒤에 부른다 — 다른 기기에서 바뀐 내용도 여기서 반영된다.
  Future<void> syncAll(List<TodoModel> todos) async {
    await init();
    for (final todo in todos) {
      await sync(todo);
    }
  }

  /// 실제 예약. sync() 와 resume() 이 함께 쓴다.
  ///
  /// payload 에 예약 시각을 넣어두는 게 핵심이다. 안드로이드는 예약 목록을
  /// 돌려줄 때 id/제목/본문/payload 만 주고 "언제" 는 안 알려주기 때문에,
  /// 세션이 끝난 뒤 원래 시각으로 되돌리려면 우리가 직접 적어둬야 한다.
  Future<void> _schedule(
    int id,
    String title,
    String body,
    tz.TZDateTime at,
  ) async {
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      at,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: at.toIso8601String(),
    );
  }

  // ── 집중 세션 중 보류 ─────────────────────────────────────────────

  /// 뽀모도로가 도는 동안 알림이 뜨지 않게 막는다.
  ///
  /// 알림은 안드로이드가 예약해뒀다가 스스로 띄우는 것이라, 뜨는 순간에
  /// 앱이 끼어들어 막을 방법이 없다. 그래서 뽀모도로가 시작될 때 예약을
  /// 통째로 걷어내고, 끝날 때 [resume] 으로 되돌린다.
  Future<void> suspend() async {
    if (_suspended) return;
    await init();
    _suspended = true;

    // 예약 시각은 payload 에 적어둔 것으로 복원한다.
    _held = await _plugin.pendingNotificationRequests();
    await _plugin.cancelAll();

    debugPrint('[알림] 뽀모도로 시작 — 예약 ${_held.length}건 보류');
  }

  /// 보류해둔 알림을 되돌린다. 세션이 끝날 때 부른다.
  ///
  /// 세션이 도는 동안 시각이 지나버린 것은 되살리지 않는다. 지난 시각으로
  /// 예약하면 안드로이드가 그 자리에서 띄우기 때문에, 집중이 끝나자마자
  /// 밀린 알림이 한꺼번에 쏟아진다.
  Future<void> resume() async {
    if (!_suspended) return;
    await init();
    _suspended = false;

    final now = tz.TZDateTime.now(tz.local);
    var restored = 0;
    var expired = 0;

    for (final held in _held) {
      final raw = held.payload;
      final parsed = raw == null ? null : DateTime.tryParse(raw);
      if (parsed == null) continue;

      final at = tz.TZDateTime.from(parsed, tz.local);
      if (!at.isAfter(now)) {
        expired++;
        continue;
      }

      await _schedule(
        held.id,
        held.title ?? '마감이 다가와요',
        held.body ?? '',
        at,
      );
      restored++;
    }

    _held = const [];
    debugPrint('[알림] 뽀모도로 종료 — $restored건 복구, $expired건은 시각이 지나 생략');
  }

  // ── 계산 ──────────────────────────────────────────────────────────

  /// 알림을 띄울 시각. 조건이 안 맞으면 null 을 준다.
  tz.TZDateTime? _scheduledTimeFor(TodoModel todo) {
    if (todo.isDone) return null;
    if (!todo.notify) return null;

    final deadline = todo.deadlineTime;
    final before = todo.notifyBefore;
    if (deadline == null || before == null) return null;

    final date = DateTime.tryParse(todo.date);
    final hm = deadline.split(':');
    if (date == null || hm.length < 2) return null;

    final hour = int.tryParse(hm[0]);
    final minute = int.tryParse(hm[1]);
    if (hour == null || minute == null) return null;

    final at = tz.TZDateTime(
      tz.local,
      date.year,
      date.month,
      date.day,
      hour,
      minute,
    ).subtract(Duration(minutes: before));

    // 이미 지난 시각이면 예약하지 않는다. 안드로이드는 과거 시각을 받으면
    // 곧바로 알림을 띄우므로, 오래된 할 일의 체크를 해제하는 순간 엉뚱한
    // 알림이 튀어나온다.
    if (!at.isAfter(tz.TZDateTime.now(tz.local))) return null;

    return at;
  }

  /// 서버의 할 일 id(문자열)를 안드로이드 알림 id(32비트 정수)로 바꾼다.
  /// 같은 할 일이 항상 같은 값이 되어야 취소가 동작한다.
  int _idOf(String todoId) {
    final n = int.tryParse(todoId);
    if (n != null) return n % 0x7FFFFFFF;
    return todoId.hashCode & 0x7FFFFFFF;
  }
}
