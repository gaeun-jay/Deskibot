import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:deskibot/services/auth_service.dart';
import 'package:deskibot/screens/auth/login_screen.dart';
import 'package:deskibot/screens/bottom_bar/bottom_bar_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    // 스플래시 최소 1.5초 보여주기
    await Future.delayed(const Duration(milliseconds: 1500));

    if (!mounted) return;

    final authService = AuthService();
    final isLoggedIn = await authService.isLoggedIn();

    // TODO: 임시 확인용 - SharedPreferences 내용 로그 출력
    final prefs = await SharedPreferences.getInstance();
    debugPrint('--- SharedPreferences ---');
    for (final key in prefs.getKeys()) {
      debugPrint('$key = ${prefs.get(key)}');
    }
    debugPrint('-------------------------');

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => isLoggedIn
            ? const BottomBarScreen()
            : const LoginScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF4A90D9),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/images/character.png', width: 120, height: 120),
            const SizedBox(height: 16),
            const Text(
              'Deskibot',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}