import 'dart:async';

import 'package:deskibot/models/todo_model.dart';
import 'package:deskibot/services/api_client.dart';

/// 할 일 서비스. Firestore 대신 FastAPI 서버를 쓴다.
///
/// 기존 인터페이스(getTodayTodos / addTodo / updateTodo / deleteTodo /
/// toggleTodo)를 그대로 유지하므로 화면 코드는 고치지 않아도 된다.
///
/// Firestore 는 snapshots() 로 실시간 갱신을 해줬지만 HTTP 는 그렇지 않다.
/// 그래서 이 클래스를 싱글톤으로 두고 브로드캐스트 스트림을 하나 유지하며,
/// 추가·수정·삭제 뒤에 스스로 다시 불러와 흘려보낸다. StreamBuilder 쪽에서
/// 보면 예전과 똑같이 동작한다.
class TodoService {
  static final TodoService _instance = TodoService._internal();

  factory TodoService() => _instance;

  TodoService._internal() {
    // 자정이 지나도 refresh()를 안 부르면 날짜가 어제에 멈춰있음 따라서 1분마다 날짜가 바뀌었는지 확인하여 새로 불러옴
    //
    // 단, 홈에서 화살표로 다른 날짜를 보고 있는 중이면(_followToday == false)
    // 손대지 않는다. 안 그러면 내일 할 일을 보던 사용자가 1분 뒤에 오늘로
    // 튕겨나간다.
    Timer.periodic(const Duration(minutes: 1), (_) {
      if (_followToday && _loadedDate != null && _loadedDate != _todayStr()) {
        refresh();
      }
    });
  }

  final ApiClient _api = ApiClient();

  final StreamController<List<TodoModel>> _controller =
      StreamController<List<TodoModel>>.broadcast();

  List<TodoModel> _cache = const [];
  String? _loadedDate;

  /// 지금 스트림에 흐르는 목록이 "오늘" 것인지. 홈에서 다른 날짜로 옮기면
  /// false 가 되고, 그동안은 자정 폴링이 목록을 건드리지 않는다.
  bool _followToday = true;

  /// 스트림에 마지막으로 흘려보낸 목록의 날짜(YYYY-MM-DD).
  ///
  /// 스트림이 싱글톤 하나뿐이라 홈이 다른 날짜로 옮기면 구독자 전부가 그
  /// 날짜의 목록을 받는다. "오늘"만 세야 하는 구독자(일간 분석 화면)는 이
  /// 값을 보고 자기가 필요한 날짜인지 판단한다.
  String get loadedDate => _loadedDate ?? _todayStr();

  static String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}'
        '-${now.day.toString().padLeft(2, '0')}';
  }

  // ── 변환 ────────────────────────────────────────────────────────────

  static TodoModel _fromServer(Map<String, dynamic> json) {
    return TodoModel(
      // 서버는 정수 ID 를 쓰고 앱 모델은 String 이다.
      id: json['id'].toString(),
      content: json['content'] as String,
      categoryId: json['category_id'] as String?,
      date: json['date'] as String,
      notify: json['notify'] as bool? ?? false,
      deadlineTime: json['deadline_time'] as String?,
      notifyBefore: json['notify_before_min'] as int?,
      isDone: json['is_done'] as bool? ?? false,
    );
  }

  static Map<String, dynamic> _toServer(TodoModel todo) {
    final notify = todo.notify && todo.deadlineTime != null;
    final categoryId = todo.categoryId;

    return {
      'content': todo.content,
      'date': todo.date,
      // 안 보내면 서버가 사용자의 첫 카테고리로 채운다.
      if (categoryId != null) 'category_id': categoryId,
      'deadline_time': todo.deadlineTime,
      'notify': notify,
      // notify 가 false 면 서버 CHECK 제약상 반드시 null 이어야 한다.
      'notify_before_min': notify ? (todo.notifyBefore ?? 0) : null,
    };
  }

  // ── 조회 ────────────────────────────────────────────────────────────

  /// 오늘 할 일 스트림. 구독하면 곧바로 한 번 불러온다.
  ///
  /// 이전에 받아둔 목록이 있으면 먼저 흘려보내 화면이 잠깐 비는 것을 막고,
  /// 이어서 서버에서 새로 불러온다.
  Stream<List<TodoModel>> getTodayTodos() {
    scheduleMicrotask(() {
      if (_cache.isNotEmpty && !_controller.isClosed) {
        _controller.add(_cache);
      }
      refresh();
    });
    return _controller.stream;
  }

  /// 서버에서 다시 불러와 스트림으로 흘려보낸다.
  Future<List<TodoModel>> refresh({String? date}) async {
    final target = date ?? _todayStr();

    try {
      final res = await _api.get('/api/todos', query: {'date': target});
      final list = (res['todos'] as List)
          .map((e) => _fromServer(Map<String, dynamic>.from(e as Map)))
          .toList();

      _cache = list;
      _loadedDate = target;
      _followToday = target == _todayStr();
      if (!_controller.isClosed) _controller.add(list);
      return list;
    } on ApiException catch (e) {
      // 로그인 전이면 빈 목록으로 둔다. 화면이 깨지지 않게.
      if (e.needsLogin) {
        _cache = const [];
        if (!_controller.isClosed) _controller.add(const []);
        return const [];
      }
      rethrow;
    }
  }

  /// 특정 날짜 조회. 스트림에는 영향을 주지 않는다.
  Future<List<TodoModel>> getTodosForDate(String date) async {
    final res = await _api.get('/api/todos', query: {'date': date});
    return (res['todos'] as List)
        .map((e) => _fromServer(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  // ── 변경 ────────────────────────────────────────────────────────────

  Future<void> addTodo(TodoModel todo) async {
    await _api.post('/api/todos', body: _toServer(todo));
    await refresh(date: _loadedDate);
  }

  Future<void> updateTodo(String todoId, TodoModel todo) async {
    await _api.patch('/api/todos/$todoId', body: _toServer(todo));
    await refresh(date: _loadedDate);
  }

  Future<void> deleteTodo(String todoId) async {
    try {
      await _api.delete('/api/todos/$todoId');
    } on ApiException catch (e) {
      // 로봇이 음성 명령으로 이미 지웠을 수 있다. 그건 오류가 아니다.
      if (e.code != 'todo_not_found') rethrow;
    }
    await refresh(date: _loadedDate);
  }

  Future<void> updateContent(String todoId, String content) async {
    await _api.patch('/api/todos/$todoId', body: {'content': content});
    await refresh(date: _loadedDate);
  }

  /// 마감 시각만 바꾼다. 없애려면 null 을 넘긴다.
  /// 마감이 사라지면 서버 CHECK 상 알림도 함께 꺼야 한다.
  Future<void> updateDeadline(String todoId, String? deadlineTime) async {
    await _api.patch('/api/todos/$todoId', body: {
      'deadline_time': deadlineTime,
      if (deadlineTime == null) 'notify': false,
      if (deadlineTime == null) 'notify_before_min': null,
    });
    await refresh(date: _loadedDate);
  }

  Future<void> toggleTodo(String todoId, bool isDone) async {
    await _api.patch('/api/todos/$todoId', body: {'is_done': isDone});
    await refresh(date: _loadedDate);
  }
}
