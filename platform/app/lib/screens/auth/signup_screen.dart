import 'package:flutter/material.dart';
import 'package:deskibot/services/auth_service.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordConfirmController = TextEditingController();
  final _nameController = TextEditingController();
  final _authService = AuthService();

  String _selectedType = ''; // 'student' | 'worker'
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _idController.dispose();
    _passwordController.dispose();
    _passwordConfirmController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _onSignup() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // 유효성 검사
    if (_idController.text.isEmpty) {
      setState(() { _errorMessage = '아이디를 입력해주세요'; _isLoading = false; });
      return;
    }
    if (_passwordController.text.isEmpty) {
      setState(() { _errorMessage = '비밀번호를 입력해주세요'; _isLoading = false; });
      return;
    }
    if (_passwordController.text != _passwordConfirmController.text) {
      setState(() { _errorMessage = '비밀번호가 일치하지 않아요'; _isLoading = false; });
      return;
    }
    if (_passwordController.text.length < 8) {
      setState(() { _errorMessage = '비밀번호는 8자 이상이어야 해요'; _isLoading = false; });
      return;
    }
    if (_nameController.text.isEmpty) {
      setState(() { _errorMessage = '이름을 입력해주세요'; _isLoading = false; });
      return;
    }
    if (_selectedType.isEmpty) {
      setState(() { _errorMessage = '유형을 선택해주세요'; _isLoading = false; });
      return;
    }

    try {
      await _authService.signUp(
        name: _nameController.text.trim(),
        userType: _selectedType,
        loginId: _idController.text.trim(),
        password: _passwordController.text,
      );
      if (mounted) {
        // 회원가입 성공 → 홈으로 이동 (나중에 연결)
        Navigator.pop(context);
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
      body: Stack(
        children: [
          // 하단 물결 이미지
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Image.asset(
              'assets/images/Bottom_background.png',
              width: double.infinity,
              fit: BoxFit.fitWidth,
            ),
          ),

          SafeArea(
            child: Column(
              children: [
                // 상단 앱바
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: const Icon(
                          Icons.close,
                          color: Color(0xFF4A90D9),
                          size: 24,
                        ),
                      ),
                      const Expanded(
                        child: Center(
                          child: Text(
                            '회원가입',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF4A90D9),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 24), // 좌우 균형용
                    ],
                  ),
                ),

                // 스크롤 영역
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 16),

                        // 아이디
                        _buildLabel('아이디'),
                        const SizedBox(height: 8),
                        _buildTextField(
                          controller: _idController,
                          hint: '아이디 입력',
                        ),
                        const SizedBox(height: 20),

                        // 비밀번호
                        _buildLabel('비밀번호'),
                        const SizedBox(height: 8),
                        _buildTextField(
                          controller: _passwordController,
                          hint: '비밀번호 입력',
                          obscure: true,
                        ),
                        const SizedBox(height: 8),
                        _buildTextField(
                          controller: _passwordConfirmController,
                          hint: '비밀번호 확인',
                          obscure: true,
                        ),
                        const SizedBox(height: 20),

                        // 이름
                        _buildLabel('이름'),
                        const SizedBox(height: 8),
                        _buildTextField(
                          controller: _nameController,
                          hint: '이름 입력',
                        ),
                        const SizedBox(height: 20),

                        // 유형
                        _buildLabel('유형'),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: _buildTypeButton(
                                label: '학생',
                                value: 'student',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildTypeButton(
                                label: '직장인',
                                value: 'worker',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        // 에러 메시지
                        if (_errorMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _errorMessage!,
                              style: const TextStyle(
                                color: Colors.red,
                                fontSize: 12,
                              ),
                            ),
                          ),

                        const SizedBox(height: 32),

                        // 회원가입 버튼
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _onSignup,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4A90D9),
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
                                    '회원가입',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 120), // 하단 물결 이미지 공간
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 라벨
  Widget _buildLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: Color(0xFF4A90D9),
      ),
    );
  }

  // 텍스트 필드
  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.grey),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF4A90D9)),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }

  // 유형 선택 버튼
  Widget _buildTypeButton({
    required String label,
    required String value,
  }) {
    final isSelected = _selectedType == value;
    return GestureDetector(
      onTap: () => setState(() => _selectedType = value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF4A90D9) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: isSelected ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }
}