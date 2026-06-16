import 'package:flutter/material.dart';
import 'package:deskibot/services/auth_service.dart';
import 'package:deskibot/screens/auth/login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _name;

  @override
  void initState() {
    super.initState();
    _loadName();
  }

  Future<void> _loadName() async {
    final name = await AuthService().getCurrentName();
    if (!mounted) return;
    setState(() => _name = name);
  }

  String get _displayName {
    final name = _name;
    if (name == null || name.isEmpty) return '';
    return name.length <= 2 ? name : name.substring(0, 2);
  }

  Future<void> _onLogout(BuildContext context) async {
    await AuthService().logout();
    if (!context.mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFFFFF),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              // 상단 헤더
              Row(
                children: [
                  Image.asset(
                    'assets/images/character.png',
                    width: 48,
                    height: 48,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.smart_toy, size: 48, color: Color(0xFF4A90D9)),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '일정 관리',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF4A90D9),
                        ),
                      ),
                      Text(
                        '오늘의 할일을 정리하고 하루를 시작하세요.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => _onLogout(context),
                    icon: const Icon(Icons.logout, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // 할일 추가 버튼
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.add, color: Colors.white),
                  label: const Text(
                    '할일 추가하기',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4A90D9),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // 오늘 할일 섹션
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFD1D1D1), width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '오늘 할일',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF4FF),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('전체 4', style: TextStyle(fontSize: 12, color: Color(0xFF4A90D9))),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 할일 목록 (하드코딩 - 나중에 실제 데이터로 교체)
                    _buildTodoItem(done: true, title: '수학 3주차 과제', tag: '과제'),
                    _buildTodoItem(done: true, title: '영어 단어 50개', tag: '공부'),
                    _buildTodoItem(done: false, title: '알고리즘 복습', time: '22:00'),
                    _buildTodoItem(done: false, title: '프로젝트 회의 준비', tag: '업무'),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 오늘의 집중 현황
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFD1D1D1), width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '오늘의 집중 현황',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF8E8E8E)),
                    ),
                    const SizedBox(height: 12),
                    GridView.count(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      childAspectRatio: 1.4,
                      children: const [
                        _StatCard(label: '집중 시간', value: '2', unit: 'h 13m', emoji: '🔥'),
                        _StatCard(label: '집중률', value: '67', unit: '%', emoji: '👀'),
                        _StatCard(label: '졸음 감지', value: '2', unit: '회', emoji: '😴'),
                        _StatCard(label: '폰 사용', value: '1', unit: '회', emoji: '📱'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTodoItem({
    required bool done,
    required String title,
    String? tag,
    String? time,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: done ? const Color(0xFF4A90D9) : Colors.grey,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                decoration: done ? TextDecoration.lineThrough : null,
                color: done ? Colors.grey : Colors.black87,
              ),
            ),
          ),
          if (tag != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFEEF4FF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(tag, style: const TextStyle(fontSize: 11, color: Color(0xFF4A90D9))),
            ),
          if (time != null)
            Row(
              children: [
                const Icon(Icons.access_time, size: 12, color: Colors.red),
                const SizedBox(width: 2),
                Text(time, style: const TextStyle(fontSize: 12, color: Colors.red)),
              ],
            ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final String emoji;

  const _StatCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.emoji,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD1D1D1), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: const Color(0xFFEEF4FF),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Color(0xFF4A90D9),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: value,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF4A90D9),
                          ),
                        ),
                        TextSpan(
                          text: unit,
                          style: const TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  Text(emoji, style: const TextStyle(fontSize: 40)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}