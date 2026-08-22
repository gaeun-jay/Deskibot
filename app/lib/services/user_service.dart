import 'dart:async';

import 'package:deskibot/models/user_model.dart';
import 'package:deskibot/services/api_client.dart';

/// 카테고리 서비스. Firestore 의 users/{uid}.settings.categories 배열 대신
/// FastAPI 의 /api/categories 를 쓴다.
///
/// 서버에는 앱에 없던 제약이 셋 있다.
///   * 유저당 최대 5개
///   * 이름 중복 불가
///   * 색상은 #RRGGBB 형식
/// 위반하면 ApiException 이 나므로 화면에서 userMessage 를 보여주면 된다.
///
/// 설정 화면에서 카테고리를 바꿔도 홈 화면 등은 IndexedStack 으로 계속
/// 살아있어 새로 안 불러온다. TodoService 와 같은 방식으로 싱글톤 브로드캐스트
/// 스트림을 하나 두고, 어디서든 목록을 불러올 때마다 흘려보내 모든 구독 화면이
/// 동시에 갱신되게 한다.
class UserService {
  static final UserService _instance = UserService._internal();

  factory UserService() => _instance;

  UserService._internal();

  final ApiClient _api = ApiClient();

  final StreamController<List<Category>> _controller =
      StreamController<List<Category>>.broadcast();

  List<Category> _cache = const [];

  /// 마지막으로 받아온 목록. 네트워크 없이 즉시 읽을 때 쓴다.
  List<Category> get cached => _cache;

  static Category _fromServer(Map<String, dynamic> json) {
    return Category(
      id: json['id'] as String,
      name: json['name'] as String,
      color: json['color'] as String,
    );
  }

  /// 카테고리 목록 스트림. 구독하면 곧바로 한 번 불러오고, 이후 앱 어디서든
  /// getCategories() 가 다시 호출될 때마다(추가/수정/삭제 뒤 등) 갱신된다.
  Stream<List<Category>> watchCategories() {
    scheduleMicrotask(() {
      if (_cache.isNotEmpty && !_controller.isClosed) {
        _controller.add(_cache);
      }
      getCategories();
    });
    return _controller.stream;
  }

  Future<List<Category>> getCategories() async {
    try {
      final res = await _api.get('/api/categories');
      _cache = (res['categories'] as List)
          .map((e) => _fromServer(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!_controller.isClosed) _controller.add(_cache);
      return _cache;
    } on ApiException catch (e) {
      // 로그인 전이면 빈 목록. 화면이 깨지지 않게 한다.
      if (e.needsLogin) return const [];
      rethrow;
    }
  }

  /// id → Category 로 바로 찾아 쓰기 좋은 형태.
  Future<Map<String, Category>> getCategoryMap() async {
    final list = await getCategories();
    return {for (final c in list) c.id: c};
  }

  Future<Category> addCategory({
    required String name,
    required String color,
  }) async {
    final res = await _api.post(
      '/api/categories',
      body: {'name': name, 'color': color},
    );
    final created = _fromServer(Map<String, dynamic>.from(res as Map));
    await getCategories();
    return created;
  }

  Future<Category> updateCategory(
    String categoryId, {
    String? name,
    String? color,
  }) async {
    final res = await _api.patch(
      '/api/categories/$categoryId',
      body: {
        if (name != null) 'name': name,
        if (color != null) 'color': color,
      },
    );
    final updated = _fromServer(Map<String, dynamic>.from(res as Map));
    await getCategories();
    return updated;
  }

  /// 할 일이 딸려 있으면 서버가 category_in_use 로 거부한다.
  Future<void> deleteCategory(String categoryId) async {
    await _api.delete('/api/categories/$categoryId');
    await getCategories();
  }
}
