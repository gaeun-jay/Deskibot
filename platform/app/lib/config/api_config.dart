/// 서버 주소 설정.
///
/// 기본값은 Android 에뮬레이터 기준 (PC localhost = 10.0.2.2).
///
/// 다른 환경에서 빌드할 때 dart-define 으로 덮어쓴다:
///
///   실제 기기 (같은 Wi-Fi)
///     flutter run --dart-define=API_BASE_URL=http://192.168.0.x:8001
///
///   iOS 시뮬레이터 / 데스크톱
///     flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8001
///
///   EC2 배포 후
///     flutter run --dart-define=API_BASE_URL=http://EC2_IP:8001
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
