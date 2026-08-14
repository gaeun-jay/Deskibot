import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:deskibot/config/api_config.dart';

/// 서버가 돌려주는 오류. 서버는 항상 아래 모양으로 응답한다.
///
///   {"detail": {"code": "...", "message": "..."}}
///
/// Pydantic 검증 실패(422)만 detail 이 배열이라 따로 처리한다.
class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  ApiException(this.statusCode, this.code, this.message);

  /// 화면에 그대로 보여줄 한국어 문구.
  String get userMessage {
    switch (code) {
      case 'invalid_credentials':
        return '아이디 또는 비밀번호를 확인해주세요';
      case 'password_not_set':
        return '이 계정은 비밀번호가 설정되어 있지 않아요';
      case 'login_id_taken':
        return '이미 사용 중인 아이디예요';
      case 'invalid_login_id':
        return '아이디는 영문·숫자 4~32자로 입력해주세요';
      case 'invalid_password':
        return '비밀번호는 8자 이상이어야 해요';
      case 'invalid_content':
        return '내용을 입력해주세요';
      case 'invalid_notify':
        return '알림을 켜려면 마감 시각을 함께 정해주세요';
      case 'no_category':
        return '카테고리를 먼저 만들어주세요';
      case 'category_not_found':
        return '없는 카테고리예요';
      case 'todo_not_found':
        return '이미 삭제된 할 일이에요';
      case 'missing_token':
      case 'invalid_token':
      case 'token_expired':
        return '다시 로그인해주세요';
      case 'network_error':
        return '서버에 연결할 수 없어요. 네트워크를 확인해주세요';
      default:
        return message.isNotEmpty ? message : '문제가 발생했어요';
    }
  }

  /// 토큰이 없거나 만료돼 재로그인이 필요한 상태인지.
  bool get needsLogin =>
      statusCode == 401 &&
      (code == 'missing_token' ||
          code == 'invalid_token' ||
          code == 'token_expired');

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}

/// FastAPI 서버와 통신하는 얇은 래퍼.
///
/// 토큰을 SharedPreferences 에 보관하고 모든 요청에 자동으로 붙인다.
class ApiClient {
  static final ApiClient _instance = ApiClient._internal();

  factory ApiClient() => _instance;

  ApiClient._internal();

  static const _tokenKey = 'server_token';

  String? _cachedToken;

  // ── 토큰 ────────────────────────────────────────────────────────────

  Future<String?> get token async {
    if (_cachedToken != null) return _cachedToken;
    final prefs = await SharedPreferences.getInstance();
    return _cachedToken = prefs.getString(_tokenKey);
  }

  Future<void> saveToken(String token) async {
    _cachedToken = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  Future<void> clearToken() async {
    _cachedToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  Future<bool> get hasToken async => (await token) != null;

  // ── 요청 ────────────────────────────────────────────────────────────

  Future<dynamic> get(String path, {Map<String, String>? query}) =>
      _send('GET', path, query: query);

  Future<dynamic> post(String path, {Object? body, bool auth = true}) =>
      _send('POST', path, body: body, auth: auth);

  Future<dynamic> patch(String path, {Object? body}) =>
      _send('PATCH', path, body: body);

  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path')
        .replace(queryParameters: query);

    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
    };

    if (auth) {
      final t = await token;
      if (t != null) headers['Authorization'] = 'Bearer $t';
    }

    final request = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);

    http.Response response;
    try {
      final streamed = await request.send().timeout(
            const Duration(seconds: 15),
          );
      response = await http.Response.fromStream(streamed);
    } catch (e) {
      throw ApiException(0, 'network_error', e.toString());
    }

    // 204 No Content
    if (response.statusCode == 204 || response.bodyBytes.isEmpty) {
      if (response.statusCode >= 400) {
        throw ApiException(response.statusCode, 'http_error', '');
      }
      return null;
    }

    // 서버는 UTF-8 로 응답한다. http 패키지 기본값이 latin-1 이라 직접 디코딩한다.
    final text = utf8.decode(response.bodyBytes);
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw ApiException(response.statusCode, 'bad_response', text);
    }

    if (response.statusCode >= 400) {
      throw _toException(response.statusCode, decoded);
    }

    return decoded;
  }

  ApiException _toException(int status, dynamic decoded) {
    if (decoded is Map && decoded['detail'] != null) {
      final detail = decoded['detail'];

      // 우리 서버가 내는 오류
      if (detail is Map) {
        return ApiException(
          status,
          detail['code']?.toString() ?? 'unknown',
          detail['message']?.toString() ?? '',
        );
      }

      // Pydantic 검증 오류(422)는 배열로 온다. 필드명을 잘못 보낸 경우 등.
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        final loc = (first is Map ? first['loc'] : null);
        final msg = (first is Map ? first['msg'] : null);
        return ApiException(
          status,
          'validation_error',
          '${loc ?? ''} ${msg ?? ''}'.trim(),
        );
      }

      return ApiException(status, 'unknown', detail.toString());
    }

    return ApiException(status, 'unknown', decoded.toString());
  }
}
