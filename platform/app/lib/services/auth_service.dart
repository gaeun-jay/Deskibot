import 'package:shared_preferences/shared_preferences.dart';

import 'package:deskibot/services/api_client.dart';

/// 회원가입 · 로그인. Firestore 대신 FastAPI 서버를 쓴다.
///
/// 예전에는 users 컬렉션에 auth.id / auth.password(SHA-256) 를 직접 넣고
/// where 쿼리로 대조했다. 이제는 서버가 Argon2id 로 해싱하고 JWT 를 발급한다.
/// 앱은 비밀번호를 해싱하지 않고 HTTPS 로 그대로 보낸다 — 클라이언트에서
/// 해싱하면 그 해시 자체가 비밀번호가 되어 오히려 약해진다.
///
/// SharedPreferences 의 'uid' 에는 서버의 users.id (UUID) 를 넣는다.
/// 아직 옮기지 않은 timer_service / splash_screen 이 이 값을 읽으므로
/// 키 이름은 그대로 둔다.
class AuthService {
  final ApiClient _api = ApiClient();

  Future<void> signUp({
    required String name,
    required String userType,
    required String loginId,
    required String password,
  }) async {
    final res = await _api.post(
      '/api/auth/signup',
      auth: false,
      body: {
        'login_id': loginId,
        'password': password,
        'name': name,
        'user_type': userType,
      },
    );

    await _persist(Map<String, dynamic>.from(res as Map));
  }

  Future<void> login({
    required String loginId,
    required String password,
  }) async {
    final res = await _api.post(
      '/api/auth/login',
      auth: false,
      body: {'login_id': loginId, 'password': password},
    );

    await _persist(Map<String, dynamic>.from(res as Map));
  }

  Future<void> _persist(Map<String, dynamic> res) async {
    final user = Map<String, dynamic>.from(res['user'] as Map);

    await _api.saveToken(res['access_token'] as String);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('uid', user['user_id'] as String);
    await prefs.setString('login_id', user['login_id'] as String);
    await prefs.setString('name', user['name'] as String);
    await prefs.setString('user_type', user['user_type'] as String);

    // 예전에는 해시된 비밀번호를 들고 있었다. 더는 필요 없다.
    await prefs.remove('password');
  }

  /// 자동 로그인 확인. 토큰이 있어야 서버를 부를 수 있다.
  Future<bool> isLoggedIn() async {
    if (!await _api.hasToken) return false;

    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('uid') != null;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('uid');
    await prefs.remove('login_id');
    await prefs.remove('password');
    await prefs.remove('name');
    await prefs.remove('user_type');
    await _api.clearToken();
  }

  Future<String?> getCurrentUid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('uid');
  }

  Future<String?> getCurrentName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('name');
  }
}
