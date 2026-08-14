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
class UserService {
  static final UserService _instance = UserService._internal();

  factory UserService() => _instance;

  UserService._internal();

  final ApiClient _api = ApiClient();

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

  Future<List<Category>> getCategories() async {
    try {
      final res = await _api.get('/api/categories');
      _cache = (res['categories'] as List)
          .map((e) => _fromServer(Map<String, dynamic>.from(e as Map)))
          .toList();
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
