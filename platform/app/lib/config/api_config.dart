/// 서버 주소 설정.
///
/// 기본값은 안드로이드 에뮬레이터 기준이다. 에뮬레이터에서 127.0.0.1 은
/// 에뮬레이터 자신을 가리키므로 PC 를 부르려면 10.0.2.2 를 써야 한다.
///
/// 다른 환경에서 돌릴 때는 빌드할 때 덮어쓴다:
///
///   실제 기기 (같은 Wi-Fi)
///     flutter run --dart-define=API_BASE_URL=http://192.168.0.10:8001
///
///   iOS 시뮬레이터 / 데스크톱
///     flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8001
///
///   EC2 (배포 후)
///     flutter run --dart-define=API_BASE_URL=https://api.deskibot.co.kr
class ApiConfig {
  const ApiConfig._();

  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8001',
  );

  /// 평문 HTTP 로 붙고 있는지. 로컬 개발에서만 true 여야 한다.
  static bool get isCleartext => baseUrl.startsWith('http://');
}
