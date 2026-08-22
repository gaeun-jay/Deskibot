/// 서버 주소 설정.
///
/// 기본값은 Android 에뮬레이터 기준 (PC localhost = 10.0.2.2).
///
/// 다른 환경에서 빌드할 때 dart-define 으로 덮어쓴다:
///
///   실제 기기 (같은 Wi-Fi)
///     flutter run --dart-define=API_BASE_URL=http://192.168.0.x:8001
///     → 그 IP 를 network_security_config.xml 에 `<domain>` 으로 추가해야 한다.
///
///   iOS 시뮬레이터 / 데스크톱
///     flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8001
///
///   운영 (EC2)
///     flutter build apk --dart-define=API_BASE_URL=https://api.deskibot.co.kr
///
/// 운영은 **반드시 https** 다. network_security_config.xml 의
/// `<base-config cleartextTrafficPermitted="false" />` 때문에, 로컬 주소
/// (10.0.2.2 / localhost / 127.0.0.1) 를 뺀 나머지에 http 로 붙으면 안드로이드가
/// 연결 자체를 차단한다. 포트까지 적어야 한다면 nginx 가 아니라 8001 에 직접
/// 붙는다는 뜻이므로, 그 경로에 TLS 가 있는지부터 확인할 것.
///
/// 비밀번호를 평문 + HTTPS 로 보내고 서버가 Argon2id 로 해싱하는 구조라
/// (docs/MIGRATION.md §4), 여기가 http 로 내려가면 비밀번호가 그대로 노출된다.
class ApiConfig {
  const ApiConfig._();

  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8001',
  );

  /// ws:// / wss:// WebSocket URL (http → ws 변환)
  static String get wsBaseUrl =>
      baseUrl.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');
}
