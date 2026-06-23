import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:deskibot/models/todo_model.dart';
import 'package:deskibot/models/focus_block_model.dart';

class TimetableService {
  final _db = FirebaseFirestore.instance;
  final _uuid = const Uuid();

  Future<String?> _getUid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('uid');
  }

  CollectionReference _todosRef(String uid) =>
      _db.collection('users').doc(uid).collection('todos');

  CollectionReference _focusRef(String uid) =>
      _db.collection('users').doc(uid).collection('focus_sessions');

  // ── Todo CRUD ─────────────────────────────────────────────────

  Future<List<TodoItem>> getTodosForDate(String date) async {
    final uid = await _getUid();
    if (uid == null) return [];

    final snapshot = await _todosRef(uid)
        .where('date', isEqualTo: date)
        .get();

    return snapshot.docs
        .map((doc) => TodoItem.fromMap(doc.id, doc.data() as Map<String, dynamic>))
        .toList();
  }

  Future<void> addTodo(TodoItem todo) async {
    final uid = await _getUid();
    if (uid == null) return;

    final id = _uuid.v4();
    await _todosRef(uid).doc(id).set({
      ...todo.toMap(),
      'created_at': FieldValue.serverTimestamp(),
    });
  }

  Future<void> toggleDone(String todoId, bool isDone) async {
    final uid = await _getUid();
    if (uid == null) return;

    await _todosRef(uid).doc(todoId).update({'is_done': isDone});
  }

  Future<void> updateContent(String todoId, String content) async {
    final uid = await _getUid();
    if (uid == null) return;

    await _todosRef(uid).doc(todoId).update({'content': content});
  }

  Future<void> deleteTodo(String todoId) async {
    final uid = await _getUid();
    if (uid == null) return;

    await _todosRef(uid).doc(todoId).delete();
  }

  // ── 집중 세션 조회 ────────────────────────────────────────────

  Future<List<FocusBlock>> getFocusBlocksForDate(String date) async {
    final uid = await _getUid();
    if (uid == null) return [];

    final snapshot = await _focusRef(uid)
        .where('start_date', isEqualTo: date)
        .get();

    return snapshot.docs
        .where((doc) {
          final d = doc.data() as Map<String, dynamic>;
          final start = d['start_time'] as String?;
          final end = d['end_time'] as String?;
          return start != null && start.isNotEmpty && end != null && end.isNotEmpty;
        })
        .map((doc) =>
            FocusBlock.fromMap(doc.id, doc.data() as Map<String, dynamic>))
        .toList();
  }

  // ── Todo 시간/색상 수정 ───────────────────────────────────────

  Future<void> updateTodoTime(
    String todoId,
    String startTime,
    String? endTime,
  ) async {
    final uid = await _getUid();
    if (uid == null) return;

    await _todosRef(uid).doc(todoId).update({
      'start_time': startTime,
      'end_time': endTime,
      'deadline_time': endTime,
    });
  }

  Future<void> updateTodoColor(String todoId, String color) async {
    final uid = await _getUid();
    if (uid == null) return;

    await _todosRef(uid).doc(todoId).update({'color': color});
  }

  // ── 집중 세션 제목 수정 ───────────────────────────────────────

  Future<void> updateFocusLabel(String sessionId, String label) async {
    final uid = await _getUid();
    if (uid == null) return;

    await _focusRef(uid).doc(sessionId).update({'title': label});
  }

  // ── 일간 집중 통계 조회 ───────────────────────────────────────

  Future<Map<String, int>> getDailyStats(String date) async {
    final uid = await _getUid();
    if (uid == null) return {};

    try {
      final doc = await _db
          .collection('users')
          .doc(uid)
          .collection('stats')
          .doc('aggregations')
          .collection('daily')
          .doc(date)
          .get();

      if (!doc.exists) return {};

      final d = doc.data()!;
      return {
        'pomodoro_duration': (d['pomodoro_duration'] as num?)?.toInt() ?? 0,
        'stopwatch_duration': (d['stopwatch_duration'] as num?)?.toInt() ?? 0,
        'drowsy_count': (d['drowsy_count'] as num?)?.toInt() ?? 0,
        'drowsy_duration': (d['drowsy_duration'] as num?)?.toInt() ?? 0,
        'phone_count': (d['phone_count'] as num?)?.toInt() ?? 0,
        'phone_duration': (d['phone_duration'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return {};
    }
  }
}
