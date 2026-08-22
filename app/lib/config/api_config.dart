/// 서버 주소 설정.
///
/// **기본값은 운영 서버(EC2)다.** 그냥 빌드하면 운영에 붙는다.
///
/// 예전에는 기본값이 `http://10.0.2.2:8001`(에뮬레이터에서 본 PC) 이었다.
/// 그러면 `--dart-define` 을 빼먹은 빌드가 조용히 개발자 PC 를 바라보게 되고,
/// 그 PC 가 꺼져 있거나 다른 사람 손에 있으면 원인을 찾기 매우 어렵다.
/// 실제로 그렇게 만든 APK 로 한참을 헤맸다. 안전한 쪽을 기본값으로 둔다.
///
/// 로컬 서버로 붙이려면 **명시적으로** 넘긴다:
///
///   안드로이드 에뮬레이터 (PC localhost = 10.0.2.2)
///     flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8001
///
///   iOS 시뮬레이터 / 데스크톱
///     flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8001
///
///   실제 기기에서 내 PC 서버로 (같은 Wi-Fi)
///     flutter run --dart-define=API_BASE_URL=http://192.168.0.x:8001
///     → 그 IP 를 network_security_config.xml 에 `<domain>` 으로 추가해야 한다.
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
    defaultValue: 'https://api.deskibot.co.kr',
  );

  /// ws:// / wss:// WebSocket URL (http → ws 변환)
  static String get wsBaseUrl =>
      baseUrl.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');
}
