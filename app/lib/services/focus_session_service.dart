import 'dart:async';

import 'package:deskibot/models/focus_session_model.dart';
import 'package:deskibot/services/api_client.dart';

/// 집중 세션 조회. Firestore 대신 FastAPI /api/focus-sessions 를 쓴다.
///
/// Firestore 는 세션 문서 안에 drowsy_events[] / phone_events[] 배열을 담아
/// 앱이 직접 개수와 합을 셌지만, 서버가 미리 집계해 내려주므로 그대로 받는다.
///
/// 단위 주의: 서버는 전부 초(_sec)로 준다. 화면은 분으로 표시하므로 여기서
/// 변환한다.
class FocusSessionService {
  static final FocusSessionService _instance =
      FocusSessionService._internal();

  factory FocusSessionService() => _instance;

  FocusSessionService._internal() {
    // 자정이 지나도 refresh()를 안 부르면 날짜가 어제에 멈춰있음 따라서 1분마다 날짜가 바뀌었는지 확인하여 새로 불러옴
    Timer.periodic(const Duration(minutes: 1), (_) {
      if (_loadedDate != null && _loadedDate != _todayStr()) {
        refresh();
      }
    });
  }

  final ApiClient _api = ApiClient();

  final StreamController<List<FocusSessionModel>> _controller =
      StreamController<List<FocusSessionModel>>.broadcast();

  List<FocusSessionModel> _cache = const [];
  String? _loadedDate;

  static String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}'
        '-${now.day.toString().padLeft(2, '0')}';
  }

  static int _toMinutes(dynamic seconds) =>
      ((seconds as int? ?? 0) / 60).round();

  static FocusSessionModel _fromServer(Map<String, dynamic> json) {
    final drowsy = Map<String, dynamic>.from(json['drowsy'] as Map);
    final phone = Map<String, dynamic>.from(json['phone'] as Map);

    return FocusSessionModel(
      id: json['session_id'] as String,
      type: json['type'] as String,
      date: json['date'] as String? ?? '',
      // 서버가 KST 로 변환해 내려준 "HH:MM". 기기 타임존에 흔들리지 않는다.
      endTime: json['end_time'] as String? ?? '00:00',
      actualDuration: _toMinutes(json['actual_duration_sec']),
      drowsyEventCount: drowsy['count'] as int? ?? 0,
      drowsyDuration: _toMinutes(drowsy['duration_sec']),
      latestDrowsyTime: drowsy['latest_at'] as String?,
      latestDrowsyDuration: _toMinutes(drowsy['latest_duration_sec']),
      phoneEventCount: phone['count'] as int? ?? 0,
      phoneDuration: _toMinutes(phone['duration_sec']),
      latestPhoneTime: phone['latest_at'] as String?,
      latestPhoneDuration: _toMinutes(phone['latest_duration_sec']),
    );
  }

  Future<List<FocusSessionModel>> _fetch(String date) async {
    final res = await _api.get('/api/focus-sessions', query: {'date': date});
    return (res['sessions'] as List)
        .map((e) => _fromServer(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// 오늘 세션 스트림.
  Stream<List<FocusSessionModel>> getTodaySessions() {
    scheduleMicrotask(() {
      if (_cache.isNotEmpty && !_controller.isClosed) {
        _controller.add(_cache);
      }
      refresh();
    });
    return _controller.stream;
  }

  Future<List<FocusSessionModel>> refresh({String? date}) async {
    final target = date ?? _todayStr();
    try {
      final list = await _fetch(target);
      _cache = list;
      _loadedDate = target;
      if (!_controller.isClosed) _controller.add(list);
      return list;
    } on ApiException catch (e) {
      if (e.needsLogin) {
        _cache = const [];
        if (!_controller.isClosed) _controller.add(const []);
        return const [];
      }
      rethrow;
    }
  }

  Future<List<FocusSessionModel>> getSessionsByDate(String date) async {
    try {
      return await _fetch(date);
    } on ApiException catch (e) {
      if (e.needsLogin) return const [];
      rethrow;
    }
  }

  /// 세션 제목 변경 (타임테이블에서 사용).
  Future<void> updateTitle(String sessionId, String title) async {
    await _api.patch(
      '/api/focus-sessions/$sessionId',
      body: {'title': title},
    );
    await refresh();
  }
}
