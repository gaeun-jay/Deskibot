import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:deskibot/models/todo_model.dart';
import 'package:deskibot/models/focus_block_model.dart';
import 'package:deskibot/models/user_model.dart';
import 'package:deskibot/services/timetable_service.dart';
import 'package:deskibot/theme/app_styles.dart';

// ── 색상 ─────────────────────────────────────────────────────────────
const _kMain  = Color(0xFF2881FF);
// 카테고리에 매칭되는 색이 없을 때만 사용하는 기본값
const _kDefaultTodoColor = '#4A90D9';


Color _hexColor(String hex) =>
    Color(int.parse(hex.replaceFirst('#', '0xFF')));

String _minutesToTime(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

// ── 화면 ─────────────────────────────────────────────────────────────
class TimetableScreen extends StatefulWidget {
  const TimetableScreen({super.key});

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  final _service = TimetableService();

  DateTime _selectedDate = DateTime.now();
  bool _showFocus = false;

  List<TodoModel> _todos = [];
  List<FocusBlock> _focusBlocks = [];
  Map<String, Category> _categories = {};
  bool _isLoading = true;
  bool _wasVisible = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));
    _loadData();
  }

  @override
  void dispose() {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isVisible = TickerMode.valuesOf(context).enabled;
    if (isVisible && !_wasVisible) _loadData();
    _wasVisible = isVisible;
  }

  String get _dateKey {
    final d = _selectedDate;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String get _dateLabel {
    final now = DateTime.now();
    final isToday = _selectedDate.year == now.year &&
        _selectedDate.month == now.month &&
        _selectedDate.day == now.day;
    final s = '${_selectedDate.month}월 ${_selectedDate.day}일';
    return isToday ? '$s (오늘)' : s;
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final results = await Future.wait([
      _service.getTodosForDate(_dateKey),
      _service.getFocusBlocksForDate(_dateKey),
      _service.getCategories(),
    ]);
    if (!mounted) return;
    setState(() {
      _todos = results[0] as List<TodoModel>;
      _focusBlocks = results[1] as List<FocusBlock>;
      _categories = results[2] as Map<String, Category>;
      _isLoading = false;
    });
  }

  // 할 일은 시작·종료 시각이 없는 체크리스트다. 그리드에는 집중 세션만 그린다.
  List<TodoModel> get _unscheduled => _todos;

  // ── 블록 레이아웃 계산 ──────────────────────────────────────────────
  List<_BlockLayout> _buildLayouts() {
    final layouts = <_BlockLayout>[];

    if (_showFocus) {
      for (final block in _focusBlocks) {
        layouts.add(_BlockLayout(
          id: block.id,
          title: block.label,
          startMinutes: block.startMinutes,
          endMinutes: block.endMinutes,
          isFocus: true,
          isDone: false,
          color: '#4A90D9',
        ));
      }
    }

    _assignColumns(layouts);
    return layouts;
  }

  void _assignColumns(List<_BlockLayout> layouts) {
    layouts.sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
    final columnEnds = <int>[];
    for (final l in layouts) {
      int col = 0;
      for (; col < columnEnds.length; col++) {
        if (columnEnds[col] <= l.startMinutes) break;
      }
      l.column = col;
      if (col == columnEnds.length) {
        columnEnds.add(l.endMinutes);
      } else {
        columnEnds[col] = l.endMinutes;
      }
    }
    for (final l in layouts) {
      int maxCol = l.column;
      for (final o in layouts) {
        if (identical(o, l)) continue;
        if (o.startMinutes < l.endMinutes && o.endMinutes > l.startMinutes && o.column > maxCol) {
          maxCol = o.column;
        }
      }
      l.totalColumns = maxCol + 1;
    }
  }

  // ── 빌드 ───────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final statusBarH = MediaQuery.of(context).padding.top;
    final headerH = statusBarH + 150.0;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4FF),
      body: Stack(
        children: [
          // ── 1) 그라디언트 배경 ───────────────────────────────
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(gradient: kAppBackgroundGradient),
            ),
          ),

          // ── 2) 캐릭터 (흰 카드 뒤, 왼쪽) ───────────────────
          Positioned(
            top: statusBarH + 16,
            left: 10,
            child: Image.asset(
              'assets/images/character_timetable.png',
              width: 143,
              height: 143,
              fit: BoxFit.contain,
            ),
          ),

          // ── 3) 헤더 텍스트 (오른쪽) ─────────────────────────
          Positioned(
            top: statusBarH + 70,
            left: 155,
            right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('Daily Log', style: kHeaderTitleStyle),
                SizedBox(height: 6),
                Text(
                  '하루 일정을 시간대별로 확인하세요.',
                  style: kHeaderSubtitleStyle,
                ),
              ],
            ),
          ),

          // ── 5) 콘텐츠 영역 (시간미정 + 토글 + 흰 카드) ──────
          Positioned(
            top: headerH,
            left: 14,
            right: 14,
            bottom: 0,
            child: Column(
              children: [
                // 시간 미정 섹션 (하루 일정)
                if (_unscheduled.isNotEmpty) ...[
                  _UnscheduledSection(
                    items: _unscheduled,
                    categories: _categories,
                    onToggle: (todo) async {
                      await _service.toggleDone(todo.id, !todo.isDone);
                      _loadData();
                    },
                    onDelete: (todo) async {
                      await _service.deleteTodo(todo.id);
                      _loadData();
                    },
                  ),
                ],

                // 토글 (타임테이블 위 오른쪽)
                Align(
                  alignment: Alignment.centerRight,
                  child: _FocusToggle(
                    showFocus: _showFocus,
                    onChanged: (v) => setState(() => _showFocus = v),
                  ),
                ),

                // 흰 카드 (타임 그리드)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(24),
                        topRight: Radius.circular(24),
                      ),
                      border: Border.all(color: const Color(0xFFD1D1D1)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x18000000),
                          blurRadius: 12,
                          offset: Offset(0, -4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        // 날짜 네비게이션
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.chevron_left, size: 22),
                                onPressed: () {
                                  setState(() => _selectedDate =
                                      _selectedDate.subtract(const Duration(days: 1)));
                                  _loadData();
                                },
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                              ),
                              Text(
                                _dateLabel,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1E1E1E),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.chevron_right, size: 22),
                                onPressed: () {
                                  setState(() => _selectedDate =
                                      _selectedDate.add(const Duration(days: 1)));
                                  _loadData();
                                },
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                        ),

                        // 타임 그리드
                        Expanded(
                          child: _isLoading
                              ? const Center(
                                  child: CircularProgressIndicator(color: _kMain))
                              : _TimeGrid(
                                  layouts: _buildLayouts(),
                                  onFocusTap: _showEditFocusLabelSheet,
                                  onTodoTap: _showTodoOptionsSheet,
                                ),
                        ),
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

  void _showEditFocusLabelSheet(String sessionId, String currentLabel) {
    final ctrl = TextEditingController(text: currentLabel);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFFDDDDDD),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text('집중 세션 이름 수정',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  final label = ctrl.text.trim();
                  if (label.isEmpty) return;
                  await _service.updateFocusLabel(sessionId, label);
                  if (!mounted) return;
                  Navigator.pop(context);
                  _loadData();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kMain,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('저장',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTodoOptionsSheet(String todoId, String title) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFDDDDDD),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: Color(0xFFE74C3C)),
              title: const Text('삭제',
                  style: TextStyle(color: Color(0xFFE74C3C))),
              onTap: () async {
                Navigator.pop(context);
                await _service.deleteTodo(todoId);
                _loadData();
              },
            ),
          ],
        ),
      ),
    );
  }

}

// ── 색상 팔레트 피커 ─────────────────────────────────────────────────

// ── 타임 그리드 ──────────────────────────────────────────────────────
class _FocusToggle extends StatelessWidget {
  final bool showFocus;
  final ValueChanged<bool> onChanged;

  const _FocusToggle({required this.showFocus, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            showFocus ? 'ToDo 랑 집중 세션 같이 보기' : 'ToDo 만 보기',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: showFocus ? _kMain : const Color(0xFF888888),
            ),
          ),
          Switch(
            value: showFocus,
            onChanged: onChanged,
            thumbColor: WidgetStateProperty.all(Colors.white),
            trackColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return _kMain;
              return const Color(0xFFCCCCCC);
            }),
            trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}

// ── 시간 미정 섹션 ──────────────────────────────────────────────────
class _UnscheduledSection extends StatelessWidget {
  final List<TodoModel> items;
  final Map<String, Category> categories;
  final ValueChanged<TodoModel> onToggle;
  final ValueChanged<TodoModel> onDelete;

  const _UnscheduledSection({
    required this.items,
    required this.categories,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD1D1D1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFFE9F2FF),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              border: Border(
                bottom: BorderSide(color: Color(0xFFD1D1D1)),
              ),
            ),
            child: const Text(
              '하루 일정',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF6286B8),
              ),
            ),
          ),
          ...List.generate(items.length, (i) {
            final todo = items[i];
            return Column(
              children: [
                if (i > 0)
                  const Divider(
                      height: 1,
                      thickness: 1,
                      indent: 16,
                      endIndent: 16,
                      color: Color(0xFFF0F0F0)),
                _UnscheduledTile(
                  todo: todo,
                  categoryName: categories[todo.categoryId]?.name,
                  chipColor: _hexColor(categories[todo.categoryId]?.color ?? _kDefaultTodoColor),
                  onToggle: () => onToggle(todo),
                  onDelete: () => onDelete(todo),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _UnscheduledTile extends StatelessWidget {
  final TodoModel todo;
  final String? categoryName;
  final Color chipColor;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _UnscheduledTile({
    required this.todo,
    required this.categoryName,
    required this.chipColor,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Text(
                todo.content,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: todo.isDone
                      ? const Color(0xFFAAAAAA)
                      : Colors.black87,
                  decoration:
                      todo.isDone ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            if (categoryName != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: chipColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  categoryName!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: chipColor,
                  ),
                ),
              ),
            // 마감 시각은 설정했을 때만 보여준다.
            if (todo.hasDeadline)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.schedule,
                        size: 14, color: Color(0xFF8E8E8E)),
                    const SizedBox(width: 3),
                    Text(
                      todo.deadlineTime!,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF8E8E8E),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

}

// ── 색상 팔레트 피커 ─────────────────────────────────────────────────

// ── 타임 그리드 ──────────────────────────────────────────────────────

class _TimeGrid extends StatelessWidget {
  final List<_BlockLayout> layouts;
  final void Function(String id, String label)? onFocusTap;
  final void Function(String id, String title)? onTodoTap;

  const _TimeGrid(
      {required this.layouts, this.onFocusTap, this.onTodoTap});

  static const double _hourH = 64.0;
  static const double _labelW = 56.0;

  @override
  Widget build(BuildContext context) {
    const double totalH = 24 * _hourH;
    return LayoutBuilder(
      builder: (ctx, bc) {
        final totalW = bc.maxWidth;
        final gridW = totalW - _labelW;
        return SingleChildScrollView(
          padding: const EdgeInsets.only(top: 8, bottom: 96),
          child: SizedBox(
            width: totalW,
            height: totalH,
            child: Stack(
              children: [
                ...List.generate(24, (h) {
                  final y = h * _hourH;
                  return Stack(children: [
                    Positioned(
                      top: y - 8,
                      left: 0,
                      width: _labelW - 8,
                      child: Text(
                        '${h.toString().padLeft(2, '0')}:00',
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFFBBBBBB)),
                      ),
                    ),
                    Positioned(
                      top: y,
                      left: _labelW,
                      width: gridW,
                      height: 1,
                      child: const ColoredBox(color: Color(0xFFEDEDED)),
                    ),
                  ]);
                }),
                ...layouts.map((l) {
                  final top = l.startMinutes * _hourH / 60;
                  final height =
                      ((l.endMinutes - l.startMinutes) * _hourH / 60)
                          .clamp(24.0, double.infinity);
                  final colW = gridW / l.totalColumns;
                  final left = _labelW + l.column * colW + 2;

                  final Color accent;
                  final Color bg;
                  final Color textC;

                  if (l.isFocus) {
                    accent = _kMain;
                    bg = const Color(0xFFE8F1FF);
                    textC = const Color(0xFF1565C0);
                  } else {
                    accent = _hexColor(l.color);
                    bg = Color.alphaBlend(accent.withValues(alpha: 0.13), Colors.white);
                    textC = Color.alphaBlend(accent.withValues(alpha: 0.75), Colors.black);
                  }

                  return Positioned(
                    top: top,
                    left: left,
                    width: colW - 4,
                    height: height,
                    child: GestureDetector(
                      onTap: l.isFocus
                          ? () => onFocusTap?.call(l.id, l.title)
                          : () => onTodoTap?.call(l.id, l.title),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.07),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(width: 4, color: accent),
                              Expanded(
                                child: Container(
                                  color: bg,
                                  padding: EdgeInsets.fromLTRB(
                                    9,
                                    height < 30 ? 4 : 8,
                                    8,
                                    height < 30 ? 2 : 6,
                                  ),
                                  child: height < 18
                                      ? const SizedBox.shrink()
                                      : Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Flexible(
                                              child: Text(
                                                l.title,
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                  color: textC,
                                                  decoration: l.isDone
                                                      ? TextDecoration
                                                          .lineThrough
                                                      : null,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                                maxLines: 1,
                                              ),
                                            ),
                                            if (height > 46)
                                              Text(
                                                '${_minutesToTime(l.startMinutes)} ~ ${_minutesToTime(l.endMinutes)}',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: textC.withValues(
                                                      alpha: 0.7),
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
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── 내부 블록 레이아웃 데이터 ────────────────────────────────────────
class _BlockLayout {
  final String id;
  final String title;
  final int startMinutes;
  final int endMinutes;
  final bool isFocus;
  final bool isDone;
  final String color;
  int column = 0;
  int totalColumns = 1;

  _BlockLayout({
    required this.id,
    required this.title,
    required this.startMinutes,
    required this.endMinutes,
    required this.isFocus,
    required this.isDone,
    required this.color,
  });
}

// ── 시간 지정 바텀시트 ───────────────────────────────────────────────
