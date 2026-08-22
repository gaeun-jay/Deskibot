import 'package:flutter/material.dart';
import 'screens/splash/splash_screen.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 마감 알림 준비. 권한을 못 받아도 앱은 그대로 뜬다 — 알림만 안 올 뿐이다.
  await NotificationService.instance.init();
  await NotificationService.instance.requestPermission();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Deskibot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A90D9)),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}