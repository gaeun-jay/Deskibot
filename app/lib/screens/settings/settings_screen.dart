import 'dart:async';

import 'package:flutter/material.dart';
import 'package:deskibot/models/user_model.dart' show Category;
import 'package:deskibot/services/api_client.dart';
import 'package:deskibot/services/auth_service.dart';
import 'package:deskibot/services/user_service.dart';
import 'package:deskibot/screens/settings/category_edit_screen.dart';
import 'package:deskibot/theme/app_styles.dart';
import 'package:deskibot/widgets/app_bottom_nav.dart';

const _kPrimaryBlue = Color(0xFF2881FF);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _settingsTabIndex = 5;

  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // 설정 화면은 IndexedStack 으로 계속 살아있어서 다른 탭에 갔다 와도
    // 내부 탭(_tab) 이 그대로 유지된다. 설정 탭으로 다시 들어올 때마다
    // "프로필 수정"부터 보이도록 리셋한다.
    BottomNavState.index.addListener(_onBottomTabChanged);
  }

  @override
  void dispose() {
    BottomNavState.index.removeListener(_onBottomTabChanged);
    super.dispose();
  }

  void _onBottomTabChanged() {
    if (BottomNavState.index.value == _settingsTabIndex && mounted) {
      setState(() => _tab = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: kAppBackgroundGradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  _buildTabBar(),
                  Expanded(
                    child: IndexedStack(
                      index: _tab,
                      children: const [
                        _ProfileTab(),
                        _CategoryTab(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Row(
        children: [
          Expanded(child: _tabItem('프로필 수정', 0)),
          Expanded(child: _tabItem('Todo 카테고리 관리', 1)),
        ],
      ),
    );
  }

  Widget _tabItem(String label, int index) {
    final selected = _tab == index;
    return GestureDetector(
      onTap: () => setState(() => _tab = index),
      child: Container(
        padding: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? _kPrimaryBlue : const Color(0xFFDFDFDF),
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: selected ? _kPrimaryBlue : const Color(0xFF8E8E8E),
          ),
        ),
      ),
    );
  }
}

// ─── 프로필 수정 ────────────────────────────────────────────────────────────

class _ProfileTab extends StatefulWidget {
  const _ProfileTab();

  @override
  State<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<_ProfileTab> {
  final _nameController = TextEditingController();
  final _loginIdController = TextEditingController();
  final _passwordController = TextEditingController();

  String _userType = 'student';
  bool _obscurePassword = true;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _loginIdController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final auth = AuthService();
    final name = await auth.getCurrentName();
    final loginId = await auth.getCurrentLoginId();
    final userType = await auth.getCurrentUserType();
    if (!mounted) return;
    setState(() {
      _nameController.text = name ?? '';
      _loginIdController.text = loginId ?? '';
      _userType = userType ?? 'student';
      _loading = false;
    });
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final loginId = _loginIdController.text.trim();

    if (name.isEmpty) {
      _showMessage('이름을 입력해주세요');
      return;
    }
    if (loginId.isEmpty) {
      _showMessage('아이디를 입력해주세요');
      return;
    }
    if (_passwordController.text.isNotEmpty && _passwordController.text.length < 8) {
      _showMessage('비밀번호는 8자 이상이어야 해요');
      return;
    }

    setState(() => _saving = true);
    try {
      await AuthService().updateProfile(
        name: name,
        loginId: loginId,
        password: _passwordController.text.isEmpty ? null : _passwordController.text,
        userType: _userType,
      );
      _passwordController.clear();
      if (!mounted) return;
      _showMessage('저장했어요');
    } on ApiException catch (e) {
      _showMessage(e.userMessage);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
      child: Column(
        children: [
          Center(
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFE8F1FF),
                border: Border.all(color: _kPrimaryBlue, width: 2),
              ),
              child: ClipOval(
                child: Transform.scale(
                  scale: 1.1,
                  child: Image.asset(
                    'assets/images/settings_character.png',
                    fit: BoxFit.cover,
                    width: 140,
                    height: 140,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          _label('이름'),
          const SizedBox(height: 8),
          _field(_nameController, hint: '이름 입력'),
          const SizedBox(height: 20),
          _label('아이디'),
          const SizedBox(height: 8),
          _field(_loginIdController, hint: '아이디 입력'),
          const SizedBox(height: 20),
          _label('비밀번호'),
          const SizedBox(height: 8),
          _field(
            _passwordController,
            hint: '변경할 때만 입력해주세요',
            obscure: _obscurePassword,
            suffix: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility_off : Icons.visibility,
                color: Colors.grey,
                size: 20,
              ),
              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          const SizedBox(height: 20),
          _label('유형'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _typeButton('학생', 'student')),
              const SizedBox(width: 12),
              Expanded(child: _typeButton('직장인', 'worker')),
            ],
          ),
          const SizedBox(height: 38),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kPrimaryBlue,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              ),
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text(
                      '저장',
                      style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.bold),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kPrimaryBlue),
        ),
      );

  Widget _field(
    TextEditingController controller, {
    required String hint,
    bool obscure = false,
    Widget? suffix,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
        suffixIcon: suffix,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: const BorderSide(color: _kPrimaryBlue),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }

  Widget _typeButton(String label, String value) {
    final selected = _userType == value;
    return GestureDetector(
      onTap: () => setState(() => _userType = value),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFDCEBFF) : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(30),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: selected ? _kPrimaryBlue : Colors.black54,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── 카테고리 관리 ──────────────────────────────────────────────────────────

class _CategoryTab extends StatefulWidget {
  const _CategoryTab();

  @override
  State<_CategoryTab> createState() => _CategoryTabState();
}

class _CategoryTabState extends State<_CategoryTab> {
  List<Category> _categories = const [];
  bool _loading = true;
  StreamSubscription<List<Category>>? _categoriesSub;

  @override
  void initState() {
    super.initState();
    // 어디서 카테고리가 바뀌든(추가/수정/삭제) 곧바로 반영되도록 구독한다.
    _categoriesSub = UserService().watchCategories().listen((list) {
      if (!mounted) return;
      setState(() {
        _categories = list;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _categoriesSub?.cancel();
    super.dispose();
  }

  Future<void> _openEditor({Category? category}) async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => CategoryEditScreen(category: category)),
    );
  }

  Future<void> _delete(Category category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('카테고리 삭제'),
        content: Text("'${category.name}' 카테고리를 삭제할까요?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await UserService().deleteCategory(category.id);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  void _showLockedMessage(Category c) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("'${c.name}'는 기본 카테고리라 바꿀 수 없어요")),
    );
  }

  Color _parseColor(String hex) {
    return Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 15, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F5F7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'Todo 카테고리를 추가, 수정하거나 삭제할 수 있습니다.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight(500), color: Color(0xFF8E8E8E)),
            ),
          ),
          const SizedBox(height: 30),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Todo 카테고리 리스트',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _kPrimaryBlue),
              ),
              Builder(builder: (_) {
                final canAdd = _categories.length < 5;
                final color = canAdd ? _kPrimaryBlue : const Color(0xFFBBBBBB);
                return GestureDetector(
                  onTap: canAdd ? () => _openEditor() : null,
                  child: Row(
                    children: [
                      Icon(Icons.add_circle, color: color, size: 20),
                      const SizedBox(width: 4),
                      Text(
                        '추가',
                        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 12),
          ..._categories.map((c) => _categoryRow(c)),
          if (_categories.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Center(
                child: Text('아직 카테고리가 없어요', style: TextStyle(color: Colors.grey)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _categoryRow(Category c) {
    final color = _parseColor(c.color);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE0E0E0)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(color: color.withValues(alpha: 0.6)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    c.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (c.isLocked) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.lock_outline,
                      size: 14, color: Color(0xFF9AA0A6)),
                ],
              ],
            ),
          ),
          // "기타"는 분류가 애매한 할 일을 받는 자리라 수정·삭제를 막는다.
          // 버튼을 없애면 줄마다 높이가 달라져 목록이 들쭉날쭉해지므로,
          // 자리는 그대로 두고 흐리게 + 눌러도 안내만 띄운다.
          _iconBoxButton(
            icon: Icons.edit_outlined,
            background: const Color(0xFFF0F0F0),
            iconColor:
                c.isLocked ? const Color(0xFFD0D0D0) : const Color(0xFF9AA0A6),
            onTap: c.isLocked
                ? () => _showLockedMessage(c)
                : () => _openEditor(category: c),
          ),
          const SizedBox(width: 8),
          _iconBoxButton(
            icon: Icons.delete_outline,
            background: c.isLocked
                ? const Color(0xFFF0F0F0)
                : const Color(0xFFFDE9E9),
            iconColor:
                c.isLocked ? const Color(0xFFD0D0D0) : const Color(0xFFE05353),
            onTap: c.isLocked ? () => _showLockedMessage(c) : () => _delete(c),
          ),
        ],
      ),
    );
  }

  Widget _iconBoxButton({
    required IconData icon,
    required Color background,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 24, color: iconColor),
      ),
    );
  }
}
