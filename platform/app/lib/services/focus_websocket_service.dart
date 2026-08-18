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
        _startPing();
        debugPrint('[WS] 인증 완료');
      } else if (type == 'pong') {
        // keep-alive 응답 — 무시
        return;
      }

      _controller.add(msg);
    } catch (e) {
      debugPrint('[WS] 메시지 파싱 오류: $e');
    }
  }

  void _onDisconnect() {
    debugPrint('[WS] 연결 끊김');
    _authenticated = false;
    _channel = null;
    _pingTimer?.cancel();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_reconnecting) return;
    _reconnecting = true;
    Future.delayed(const Duration(seconds: 5), () async {
      _reconnecting = false;
      await connect();
    });
  }

  // ── ping (연결 유지) ───────────────────────────────────────────────

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_authenticated) _send({'type': 'ping'});
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
    _channel?.sink.close();
    _channel = null;
    _authenticated = false;
  }
}
