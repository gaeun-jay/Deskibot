import 'package:deskibot/models/todo_model.dart';
import 'package:deskibot/models/focus_block_model.dart';
import 'package:deskibot/models/user_model.dart';
import 'package:deskibot/services/api_client.dart';
import 'package:deskibot/services/focus_session_service.dart';
import 'package:deskibot/services/todo_service.dart';
import 'package:deskibot/services/user_service.dart';

/// 타임테이블 화면용 조합 서비스.
/// 실제 저장소 접근은 TodoService / FocusSessionService / UserService 가 한다.
class TimetableService {
  // ── Todo CRUD ─────────────────────────────────────────────────

  Future<List<TodoModel>> getTodosForDate(String date) =>
      TodoService().getTodosForDate(date);

  Future<void> addTodo(TodoModel todo) => TodoService().addTodo(todo);

  Future<void> toggleDone(String todoId, bool isDone) =>
      TodoService().toggleTodo(todoId, isDone);

  Future<void> updateContent(String todoId, String content) =>
      TodoService().updateContent(todoId, content);

  Future<void> deleteTodo(String todoId) => TodoService().deleteTodo(todoId);

  // ── 집중 세션 조회 ────────────────────────────────────────────

  /// 서버에서 세션을 받아 타임테이블 블록으로 바꾼다.
  /// 시작·종료 시각이 모두 있는(= 끝난) 세션만 블록으로 그린다.
  Future<List<FocusBlock>> getFocusBlocksForDate(String date) async {
    final res = await ApiClient()
        .get('/api/focus-sessions', query: {'date': date});

    final blocks = <FocusBlock>[];

    for (final raw in (res['sessions'] as List)) {
      final s = Map<String, dynamic>.from(raw as Map);
      final start = s['start_time'] as String?;
      final end = s['end_time'] as String?;

      if (start == null || end == null) continue;

      final type = s['type'] as String? ?? 'pomodoro';

      blocks.add(FocusBlock(
        id: s['session_id'] as String,
        date: s['date'] as String? ?? date,
        startTime: start,
        endTime: end,
        sessionType: type,
        label: (s['title'] as String?) ??
            (type == 'pomodoro' ? '뽀모도로' : '스톱워치'),
        // 서버는 초, 타임테이블은 분.
        durationMin: (((s['actual_duration_sec'] as int? ?? 0)) / 60).round(),
      ));
    }

    return blocks;
  }

  // ── 집중 세션 제목 수정 ───────────────────────────────────────

  Future<void> updateFocusLabel(String sessionId, String label) =>
      FocusSessionService().updateTitle(sessionId, label);

  // ── 카테고리 조회 ─────────────────────────────────────────────

  // 카테고리는 서버로 옮겼다. UserService 가 /api/categories 를 부른다.
  Future<Map<String, Category>> getCategories() =>
      UserService().getCategoryMap();

  // ── 일간 집중 통계 조회 ───────────────────────────────────────

  /// 서버는 초 단위, 화면은 분 단위라 여기서 변환한다.
  Future<Map<String, int>> getDailyStats(String date) async {
    int toMin(dynamic sec) => ((sec as int? ?? 0) / 60).round();

    try {
      final res = await ApiClient()
          .get('/api/stats/daily', query: {'date': date});
      final d = Map<String, dynamic>.from(res as Map);

      return {
        'pomodoro_duration': toMin(d['pomodoro_duration_sec']),
        'stopwatch_duration': toMin(d['stopwatch_duration_sec']),
        'drowsy_count': d['drowsy_count'] as int? ?? 0,
        'drowsy_duration': toMin(d['drowsy_duration_sec']),
        'phone_count': d['phone_count'] as int? ?? 0,
        'phone_duration': toMin(d['phone_duration_sec']),
      };
    } catch (_) {
      return {};
    }
  }
}
