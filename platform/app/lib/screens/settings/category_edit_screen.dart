import 'package:flutter/material.dart';
import 'package:deskibot/models/user_model.dart' show Category;
import 'package:deskibot/services/user_service.dart';
import 'package:deskibot/services/api_client.dart';
import 'package:deskibot/theme/app_styles.dart';
import 'package:deskibot/widgets/app_bottom_nav.dart';

const _kPrimaryBlue = Color(0xFF2881FF);

/// Todo 카테고리 추가/수정 화면.
/// category 가 null 이면 새로 만들고, 있으면 그 카테고리를 수정한다.
class CategoryEditScreen extends StatefulWidget {
  final Category? category;

  const CategoryEditScreen({super.key, this.category});

  @override
  State<CategoryEditScreen> createState() => _CategoryEditScreenState();
}

class _CategoryEditScreenState extends State<CategoryEditScreen> {
  static const _presetColors = [
    '#0F5DCD',
    '#0069FF',
    '#2881FF',
    '#67A5FF',
    '#9FC7FF',
    '#00D0FF',
    '#22D3C7',
    '#5FE1D6',
    '#9BEEE6',
    '#34D399',
    '#6EE7B4',
    '#A7F3D0',
    '#C824B0',
    '#EC4899',
    '#F472B6',
    '#F9A8D4',
    '#F5C2F7',
    '#DC2626',
    '#FF9C3A',
    '#FBBF24',
    '#FDE047',
    '#535353',
    '#858585',
    '#C0C0C0',
  ];

  late final TextEditingController _nameController;
  late List<String> _colors;
  String? _selectedColor;
  bool _saving = false;

  bool get _isEdit => widget.category != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.category?.name ?? '');
    _colors = List.of(_presetColors);
    _selectedColor = widget.category?.color.toUpperCase();
    if (_selectedColor != null && !_colors.contains(_selectedColor)) {
      _colors.add(_selectedColor!);
    }
    // 이 화면은 항상 설정(카테고리 관리)에서 열리니 하단 탭도 "설정"으로 고정한다.
    BottomNavState.index.value = 5;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showMessage('카테고리 이름을 입력해주세요');
      return;
    }
    if (_selectedColor == null) {
      _showMessage('색상을 선택해주세요');
      return;
    }

    setState(() => _saving = true);
    try {
      if (_isEdit) {
        await UserService().updateCategory(
          widget.category!.id,
          name: name,
          color: _selectedColor,
        );
      } else {
        await UserService().addCategory(name: name, color: _selectedColor!);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      _showMessage(e.userMessage);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Color _parseColor(String hex) {
    return Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));
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
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.chevron_left,
                            color: _kPrimaryBlue,
                            size: 40,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                        const Expanded(
                          child: Center(
                            child: Text(
                              'Todo 카테고리',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: _kPrimaryBlue,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 40),
                      ],
                    ),
                  ),
                  const Divider(height: 2, color: Color(0xFFDFDFDF)),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '카테고리 이름',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: _kPrimaryBlue,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _nameController,
                            decoration: InputDecoration(
                              hintText: '입력',
                              hintStyle: const TextStyle(color: Colors.grey),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(30),
                                borderSide: const BorderSide(
                                  color: Color(0xFFDDDDDD),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(30),
                                borderSide: const BorderSide(
                                  color: Color(0xFFDDDDDD),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(30),
                                borderSide: const BorderSide(
                                  color: Color(0xFF4A90D9),
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),
                          const Divider(height: 32, thickness: 2, color: Color(0xFFDFDFDF)),
                          const Text(
                            '카테고리 색상',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: _kPrimaryBlue,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF7F7F9),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _colors.length,
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 6,
                                    mainAxisSpacing: 14,
                                    crossAxisSpacing: 12,
                                  ),
                              itemBuilder: (_, i) {
                                final hex = _colors[i];
                                final color = _parseColor(hex);
                                final selected = _selectedColor == hex;
                                return GestureDetector(
                                  onTap: () =>
                                      setState(() => _selectedColor = hex),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: color,
                                      border: Border.all(
                                        color: selected
                                            ? const Color(0xFF656565)
                                            : const Color(0xFFA9A9A9),
                                        width: selected ? 2.5 : 1.5,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 40),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _saving ? null : _save,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _kPrimaryBlue,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(30),
                                ),
                              ),
                              child: _saving
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      '완료',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: AppBottomNavBar(
        currentIndex: 5, // 설정
        onTap: (index) {
          BottomNavState.index.value = index;
          Navigator.of(context).popUntil((route) => route.isFirst);
        },
      ),
    );
  }
}
