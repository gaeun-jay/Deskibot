// lib/services/focus_websocket_service.dart
//
// /ws/focus WebSocket 연결 관리자.
//
// 연결 흐름:
//   1. connect() → ws://server/ws/focus 연결
//   2. {"type":"auth","token":JWT,"source":"app"} 전송
//   3. {"type":"auth_ok"} 수신 → 인증 완료
//   4. {"type":"focus_state","session":...} 수신 → 현재 세션 초기 동기화
//   5. 이후 focus_start/pause/resume/end 명령 전송 + 이벤트 수신
//
// 서버 메시지 형식:
//   focus_state    : 세션 상태 변경 (start/pause/resume/end)
//   detection_event: 졸음·폰 감지 (ESP32 전용 발신, 앱은 수신만)
//   error          : 명령 처리 실패
//   pong           : ping 응답

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:deskibot/config/api_config.dart';
import 'package:deskibot/services/api_client.dart';

class FocusWebSocketService {
  static final FocusWebSocketService instance = FocusWebSocketService._();
  FocusWebSocketService._();

  WebSocketChannel? _channel;
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  bool _authenticated = false;
  bool _reconnecting = false;
  Timer? _pingTimer;

  // ── 재연결 백오프 ─────────────────────────────────────────────────
  //
  // 예전에는 5초 고정으로 무한 재시도했다. 서버가 30분 내려가 있으면 앱이
  // 360번을 헛되이 두드리고, 더 나쁜 건 서버가 살아나는 순간 모든 기기가
  // 동시에 몰려들어 갓 올라온 서버를 다시 넘어뜨릴 수 있다는 점이다.
  //
  // 실패할수록 간격을 두 배로 늘리고 상한을 둔다. 연결에 성공하면 되돌린다.
  static const Duration _minReconnectDelay = Duration(seconds: 5);
  static const Duration _maxReconnectDelay = Duration(seconds: 60);

  Duration _reconnectDelay = _minReconnectDelay;
  final Random _random = Random();

  // ── 죽은 연결 감지 ────────────────────────────────────────────────
  //
  // 비행기 모드·지하철·배터리 방전처럼 기기가 갑자기 사라지면 TCP 종료
  // 신호가 나가지 않는다. 그러면 onDone/onError 가 불리지 않아 앱은 계속
  // "연결됨"으로 착각하고, connect() 는 _authenticated 가 true 라 즉시
  // 돌아가므로 재연결을 시도조차 하지 않는다. 실제로 그 상태로 6분 넘게
  // 멈춰 있었고, 그동안 focus_end 가 서버에 닿지 못해 세션이 in_progress
  // 로 갇혔다.
  //
  // ping 은 원래도 보내고 있었지만 응답을 확인하지 않았다. 마지막 pong
  // 시각을 기록해 두고, 그보다 오래 조용하면 끊긴 것으로 보고 정리한다.
  static const Duration _pingInterval = Duration(seconds: 20);
  static const Duration _pongTimeout = Duration(seconds: 50); // ping 2회분 + 여유

  // 화면을 켜고 돌아왔을 때 쓰는 짧은 확인 시간.
  //
  // 정기 ping 은 20초마다 돌고 50초를 기다려 주지만, 그건 백그라운드에서
  // 조용히 감시할 때 이야기다. 사용자가 화면을 켜고 앱을 보고 있는 순간에는
  // 25초를 기다리는 사이 "종료됐는데 타이머가 그대로" 로 보인다.
  static const Duration _resumeProbeTimeout = Duration(seconds: 3);

  DateTime? _lastPongAt;

  // 재연결 대기를 취소할 수 있어야 해서 Future.delayed 대신 Timer 를 쓴다.
  // 화면 복귀처럼 "지금 당장 붙어야 하는" 순간에 남은 백오프를 건너뛴다.
  Timer? _reconnectTimer;
  Timer? _resumeProbeTimer;

  /// 모든 서버 메시지를 브로드캐스트하는 스트림
  Stream<Map<String, dynamic>> get stream => _controller.stream;

  bool get isConnected => _authenticated;

  // ── 연결 ──────────────────────────────────────────────────────────

  Future<void> connect() async {
    if (_authenticated) return;

    final token = await ApiClient().token;
    if (token == null) {
      debugPrint('[WS] 토큰 없음 → 연결 중단');
      return;
    }

    final wsUrl = '${ApiConfig.wsBaseUrl}/ws/focus';
    debugPrint('[WS] 연결 시도: $wsUrl');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // 인증 메시지 전송
      _send({'type': 'auth', 'token': token, 'source': 'app'});

      _channel!.stream.listen(
        _onMessage,
        onDone: _onDisconnect,
        onError: (e) {
          debugPrint('[WS] 오류: $e');
          _onDisconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[WS] 연결 실패: $e');
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final msg = json.decode(raw as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;

      if (type == 'auth_ok') {
        _authenticated = true;
        // 연결이 실제로 성립했으므로 백오프를 처음 값으로 되돌린다.
        // 이게 없으면 한 번 끊긴 뒤로는 계속 60초 간격이 되어, 잠깐
        // 끊겼다 붙는 흔한 경우에도 1분을 기다리게 된다.
        _reconnectDelay = _minReconnectDelay;
        _startPing();
        debugPrint('[WS] 인증 완료');
      } else if (type == 'pong') {
        // keep-alive 응답. 이 시각이 "서버가 아직 살아있다"는 유일한 증거다.
        _lastPongAt = DateTime.now();
        return;
      }

      // 어떤 메시지든 도착했다는 건 연결이 살아있다는 뜻이다.
      _lastPongAt = DateTime.now();

      _controller.add(msg);
    } catch (e) {
      debugPrint('[WS] 메시지 파싱 오류: $e');
    }
  }

  void _onDisconnect() {
    // ping 타임아웃에서 직접 부르는 경로와 onDone/onError 콜백 경로가 겹칠 수
    // 있다. 이미 정리된 상태면 재연결을 두 번 잡지 않도록 여기서 멈춘다.
    if (!_authenticated && _channel == null) return;

    debugPrint('[WS] 연결 끊김');
    _authenticated = false;
    _channel = null;
    _lastPongAt = null;
    _pingTimer?.cancel();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_reconnecting) return;
    _reconnecting = true;

    // 지터: 실제 대기에 ±20% 를 섞는다. 서버가 복구될 때 모든 기기가 같은
    // 초에 재연결하지 않도록 시각을 흩뿌리는 것이 목적이다.
    final base = _reconnectDelay.inMilliseconds;
    final jitter = (base * 0.2 * (_random.nextDouble() * 2 - 1)).round();
    final wait = Duration(milliseconds: base + jitter);

    debugPrint('[WS] ${(wait.inMilliseconds / 1000).toStringAsFixed(1)}초 후 재연결');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(wait, () async {
      _reconnecting = false;
      // 다음 실패를 대비해 미리 두 배로 늘려둔다 (상한까지).
      final next = _reconnectDelay * 2;
      _reconnectDelay =
          next > _maxReconnectDelay ? _maxReconnectDelay : next;
      await connect();
    });
  }

  /// 남은 백오프를 버리고 지금 바로 붙는다.
  ///
  /// 백오프는 "서버가 죽어 있을 때 몰려들지 않기" 위한 것이라, 사용자가 앱을
  /// 보고 있는 순간에는 지킬 이유가 없다.
  void _reconnectNow() {
    _reconnectTimer?.cancel();
    _reconnecting = false;
    _reconnectDelay = _minReconnectDelay;
    connect();
  }

  // ── 화면 복귀 시 즉시 확인 ─────────────────────────────────────────

  /// 앱이 포그라운드로 돌아왔을 때 부른다. 연결이 살아있는지 즉시 확인하고,
  /// 죽었으면 백오프를 기다리지 않고 곧바로 다시 붙는다.
  ///
  /// 이게 없으면 정기 ping 차례(최대 20초)를 기다린 뒤에야 끊김을 알아채고,
  /// 거기에 백오프까지 더해져 25초 넘게 옛 상태가 화면에 남는다. 로봇이
  /// 화면 꺼진 사이 세션을 끝낸 경우가 정확히 그랬다 — 서버의 현재 상태는
  /// 재연결할 때 오는 스냅샷으로만 오기 때문이다.
  void verifyConnection() {
    // 이미 끊긴 걸 아는 상태 — 기다릴 것 없이 바로.
    if (!_authenticated) {
      debugPrint('[WS] 화면 복귀 — 끊긴 상태라 즉시 재연결');
      _reconnectNow();
      return;
    }

    // 최근까지 응답이 있었으면 살아있는 것으로 본다. 소켓이 살아있다면
    // 놓친 메시지도 없다(TCP 가 순서대로 전달하고, 복귀 시 처리된다).
    final last = _lastPongAt;
    if (last != null &&
        DateTime.now().difference(last) <= _pingInterval) {
      return;
    }

    // 조용했다. 죽었는지 아직 모르니 ping 을 던지고 짧게만 기다려 본다.
    // 곧바로 끊어버리면 멀쩡한 연결까지 매번 새로 맺게 된다.
    _send({'type': 'ping'});

    _resumeProbeTimer?.cancel();
    _resumeProbeTimer = Timer(_resumeProbeTimeout, () {
      final at = _lastPongAt;
      final alive = at != null &&
          DateTime.now().difference(at) <= _resumeProbeTimeout;
      if (alive) return;

      debugPrint('[WS] 화면 복귀 후 ${_resumeProbeTimeout.inSeconds}초간 응답 없음 '
          '→ 즉시 재연결');
      _channel?.sink.close();
      _onDisconnect();   // 여기서 백오프 예약이 잡히므로
      _reconnectNow();   // 곧바로 취소하고 지금 붙는다
    });
  }

  // ── ping (연결 유지) ───────────────────────────────────────────────

  void _startPing() {
    _pingTimer?.cancel();
    _lastPongAt = DateTime.now();

    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (!_authenticated) return;

      // 먼저 지난 응답을 확인한다. 조용한 지 오래면 소켓이 이미 죽은 것으로
      // 본다 — 여기서 끊어주지 않으면 아무도 끊김을 알려주지 않는다.
      final last = _lastPongAt;
      if (last != null && DateTime.now().difference(last) > _pongTimeout) {
        debugPrint('[WS] ${_pongTimeout.inSeconds}초간 응답 없음 → 끊긴 것으로 처리');
        _channel?.sink.close();
        _onDisconnect();
        return;
      }

      _send({'type': 'ping'});
    });
  }

  // ── 메시지 전송 ───────────────────────────────────────────────────

  void _send(Map<String, dynamic> message) {
    try {
      _channel?.sink.add(json.encode(message));
    } catch (e) {
      debugPrint('[WS] 전송 오류: $e');
    }
  }

  /// 명령 전송 후 대응하는 focus_state 응답을 기다린다.
  /// 타임아웃 또는 에러 수신 시 null 반환.
  Future<Map<String, dynamic>?> sendAndAwait(
    Map<String, dynamic> message, {
    String? expectedAction,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!_authenticated) {
      debugPrint('[WS] 인증되지 않은 상태 → 명령 전송 불가');
      return null;
    }

    final completer = Completer<Map<String, dynamic>?>();
    StreamSubscription? sub;

    sub = _controller.stream.listen((msg) {
      final type = msg['type'] as String?;
      final action = msg['action'] as String?;
      final cmd = msg['command'] as String?;

      // 성공 응답
      if (type == 'focus_state' &&
          (expectedAction == null || action == expectedAction)) {
        if (!completer.isCompleted) completer.complete(msg);
        sub?.cancel();
      }
      // 에러 응답 (이 명령에 대한 것)
      else if (type == 'error' &&
          (cmd == message['type'] || expectedAction == null)) {
        if (!completer.isCompleted) completer.complete(null);
        sub?.cancel();
      }
    });

    _send(message);

    try {
      return await completer.future.timeout(timeout);
    } catch (_) {
      debugPrint('[WS] 응답 타임아웃: ${message['type']}');
      sub.cancel();
      return null;
    }
  }

  // ── 해제 ──────────────────────────────────────────────────────────

  void disconnect() {
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _resumeProbeTimer?.cancel();
    _reconnecting = false;
    _channel?.sink.close();
    _channel = null;
    _authenticated = false;
  }
}
