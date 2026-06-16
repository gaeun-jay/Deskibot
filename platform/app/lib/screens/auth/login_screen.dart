import 'package:flutter/material.dart';
import 'package:deskibot/services/auth_service.dart';
import 'package:deskibot/screens/auth/signup_screen.dart';
import 'package:deskibot/screens/bottom_bar/bottom_bar_screen.dart';
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _idController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _onLogin() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    if (_idController.text.isEmpty) {
      setState(() {
        _errorMessage = '아이디를 입력해주세요';
        _isLoading = false;
      });
      return;
    }
    if (_passwordController.text.isEmpty) {
      setState(() {
        _errorMessage = '비밀번호를 입력해주세요';
        _isLoading = false;
      });
      return;
    }

    try {
      await _authService.login(
        loginId: _idController.text.trim(),
        password: _passwordController.text,
      );
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const BottomBarScreen()),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 상단 헤더 이미지 (물결 + 캐릭터)
            Image.asset(
              'assets/images/Top_background.png',
              width: double.infinity,
              fit: BoxFit.fitWidth,
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 32),

                  // 로그인 타이틀
                  const Text(
                    '로그인',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF4A90D9),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 아이디 입력
                  TextField(
                    controller: _idController,
                    decoration: InputDecoration(
                      hintText: '아이디 입력',
                      prefixIcon: const Icon(Icons.person_outline,
                          color: Colors.grey),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // 비밀번호 입력
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      hintText: '비밀번호 입력',
                      prefixIcon: const Icon(Icons.lock_outline,
                          color: Colors.grey),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // 에러 메시지
                  if (_errorMessage != null)
                    Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 12,
                      ),
                    ),
                  const SizedBox(height: 16),

                  // 로그인 버튼
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _onLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color.fromRGBO(66, 144, 255, 1),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              '로그인',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 또는 구분선
                  Row(
                    children: [
                      const Expanded(child: Divider(color: Colors.grey)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '또는',
                          style: TextStyle(color: Colors.grey[500]),
                        ),
                      ),
                      const Expanded(child: Divider(color: Colors.grey)),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 회원가입 버튼
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SignupScreen(),
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color.fromRGBO(219, 234, 255, 1),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        '회원가입',
                        style: TextStyle(
                          fontSize: 16,
                          color: Color.fromRGBO(66, 144, 255, 1),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}