import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:deskibot/models/todo_model.dart';
import 'package:deskibot/services/auth_service.dart';

class TodoService {
  final _db = FirebaseFirestore.instance;

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Stream<List<TodoModel>> getTodayTodos() {
    final today = _todayStr();
    return Stream.fromFuture(AuthService().getCurrentUid()).asyncExpand((uid) {
      if (uid == null) return Stream.value([]);
      return _db
          .collection('users')
          .doc(uid)
          .collection('todos')
          .where('date', isEqualTo: today)
          .snapshots()
          .map((snap) => snap.docs
              .map((doc) => TodoModel.fromMap(doc.id, doc.data()))
              .toList());
    });
  }

  Future<void> addTodo(TodoModel todo) async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) return;
    await _db.collection('users').doc(uid).collection('todos').add(todo.toMap());
  }

  Future<void> updateTodo(String todoId, TodoModel todo) async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) return;
    await _db
        .collection('users')
        .doc(uid)
        .collection('todos')
        .doc(todoId)
        .update(todo.toMap());
  }

  Future<void> deleteTodo(String todoId) async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) return;
    await _db
        .collection('users')
        .doc(uid)
        .collection('todos')
        .doc(todoId)
        .delete();
  }

  Future<void> toggleTodo(String todoId, bool isDone) async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) return;
    await _db
        .collection('users')
        .doc(uid)
        .collection('todos')
        .doc(todoId)
        .update({'is_done': isDone});
  }
}