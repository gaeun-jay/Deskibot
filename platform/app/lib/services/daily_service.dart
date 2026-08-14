import 'package:deskibot/models/daily_model.dart';
import 'package:deskibot/services/api_client.dart';

/// 일간 통계·분석. Firestore 대신 FastAPI 를 쓴다.
///
///   stats/aggregations/daily/{date}  →  GET /api/stats/daily
///   analysis/{date}                  →  GET /api/analysis/daily
///
/// 서버는 모든 시간을 초로 준다. DailyModel 은 분을 기대하므로 여기서 바꾼다.
class DailyService {
  final ApiClient _api = ApiClient();

  static String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}'
        '-${now.day.toString().padLeft(2, '0')}';
  }

  static int _toMinutes(dynamic seconds) =>
      ((seconds as int? ?? 0) / 60).round();

  /// 오늘의 공부일지.
  ///
  /// title / subtitle 은 analysis_daily 에 저장할 컬럼이 없어 항상 빈 값이다.
  /// 화면에는 title 이 없을 때의 대체 분기가 이미 있다.
  Future<Map<String, String>?> getTodayAnalysis({String? date}) async {
    try {
      final res = await _api.get(
        '/api/analysis/daily',
        query: {'date': date ?? _todayStr()},
      );
      final map = Map<String, dynamic>.from(res as Map);

      return {
        'title': (map['title'] as String?) ?? '',
        'subtitle': (map['subtitle'] as String?) ?? '',
        'advice': (map['advice'] as String?) ?? '',
      };
    } on ApiException catch (e) {
      // 아직 생성 안 됨(404)이거나 로그인 전.
      if (e.statusCode == 404 || e.needsLogin) return null;
      rethrow;
    }
  }

  /// 오늘의 공부일지를 새로 생성한다 (Claude 호출).
  Future<Map<String, String>?> generateTodayAnalysis({String? date}) async {
    try {
      final res = await _api.post(
        '/api/analysis/daily/generate',
        body: null,
      );
      final map = Map<String, dynamic>.from(res as Map);

      return {
        'title': (map['title'] as String?) ?? '',
        'subtitle': (map['subtitle'] as String?) ?? '',
        'advice': (map['advice'] as String?) ?? '',
      };
    } on ApiException catch (e) {
      if (e.needsLogin) return null;
      rethrow;
    }
  }

  Future<DailyModel?> getTodayData({String? date}) async {
    final target = date ?? _todayStr();

    try {
      final res = await _api.get(
        '/api/stats/daily',
        query: {'date': target},
      );
      final map = Map<String, dynamic>.from(res as Map);

      return DailyModel(
        date: target,
        drowsyCount: map['drowsy_count'] as int? ?? 0,
        drowsyDuration: _toMinutes(map['drowsy_duration_sec']),
        phoneCount: map['phone_count'] as int? ?? 0,
        phoneDuration: _toMinutes(map['phone_duration_sec']),
        pomodoroCount: map['pomodoro_count'] as int? ?? 0,
        pomodoroDuration: _toMinutes(map['pomodoro_duration_sec']),
        stopwatchCount: map['stopwatch_count'] as int? ?? 0,
        stopwatchDuration: _toMinutes(map['stopwatch_duration_sec']),
      );
    } on ApiException catch (e) {
      if (e.needsLogin) return null;
      rethrow;
    }
  }
}
