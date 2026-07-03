import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
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

    if (isLoggedIn) {
      final uid = prefs.getString('uid');
      if (uid != null) {
        await FirebaseDatabase.instance.ref('users/$uid/status/current_state').set({
          'session_id': '',
          'type': '',
          'state': '',
          'duration': 0,
          'started_at': '',
          'paused_at': '',
          'total_pause_sec': 0,
          'is_detecting_drowsy': false,
          'is_detecting_phone': false,
        });
      }
    }

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
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xCC0069FF),
              Color(0x000069FF),
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset('assets/images/Home_character.png', width: 140, height: 140),
              const SizedBox(height: 16),
              const Text(
                'Deskibot',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Color.fromRGBO(40, 129, 255, 1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}