import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:deskibot/models/todo_item_model.dart';
import 'package:deskibot/models/focus_block_model.dart';
import 'package:deskibot/services/timetable_service.dart';

// ── 색상 ─────────────────────────────────────────────────────────────
const _kBlue1 = Color(0xFF4491FF);
const _kBlue2 = Color(0xFF68A6FF);
const _kMain  = Color(0xFF2881FF);


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

  List<TodoItem> _todos = [];
  List<FocusBlock> _focusBlocks = [];
  Map<String, String> _categoryColors = {};
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
      _todos = results[0] as List<TodoItem>;
      _focusBlocks = results[1] as List<FocusBlock>;
      _categoryColors = results[2] as Map<String, String>;
      _isLoading = false;
    });
  }

  List<TodoItem> get _unscheduled => _todos.where((t) => !t.hasTime).toList();
  List<TodoItem> get _scheduled   => _todos.where((t) => t.hasTime).toList();

  // ── 블록 레이아웃 계산 ──────────────────────────────────────────────
  List<_BlockLayout> _buildLayouts() {
    final layouts = <_BlockLayout>[];

    for (final todo in _scheduled) {
      final color = (todo.categoryId != null && _categoryColors.containsKey(todo.categoryId))
          ? _categoryColors[todo.categoryId]!
          : todo.color;
      layouts.add(_BlockLayout(
        id: todo.id,
        title: todo.content,
        startMinutes: todo.startMinutes,
        endMinutes: todo.endMinutes,
        isFocus: false,
        isDone: todo.isDone,
        color: color,
      ));
    }

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
    final headerH = statusBarH + 170.0;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4FF),
      body: Stack(
        children: [
          // ── 1) 그라디언트 배경 ───────────────────────────────
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [_kBlue1, _kBlue2, Color(0xFFD6E4FF), Color(0xFFF0F4FF)],
                  stops: [0.0, 0.12, 0.28, 1.0],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),

          // ── 2) 캐릭터 (흰 카드 뒤, 왼쪽) ───────────────────
          Positioned(
            top: statusBarH - 10,
            left: -5,
            child: Image.asset(
              'assets/images/character_timetable.png',
              width: 160,
              height: 178,
              fit: BoxFit.contain,
            ),
          ),

          // ── 3) 헤더 텍스트 (오른쪽) ─────────────────────────
          Positioned(
            top: statusBarH + 44,
            left: 155,
            right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Daily Log',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        offset: Offset(1, 1),
                        blurRadius: 1,
                        color: Color(0x80000000),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '하루 일정을 시간대별로 확인하세요.',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    height: 1.4,
                  ),
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
                // 토글 (타임테이블 위 오른쪽)
                Align(
                  alignment: Alignment.centerRight,
                  child: _FocusToggle(
                    showFocus: _showFocus,
                    onChanged: (v) => setState(() => _showFocus = v),
                  ),
                ),

                // 시간 미정 섹션 (흰 카드 위)
                if (_unscheduled.isNotEmpty) ...[
                  _UnscheduledSection(
                    items: _unscheduled,
                    categoryColors: _categoryColors,
                    onToggle: (todo) async {
                      await _service.toggleDone(todo.id, !todo.isDone);
                      _loadData();
                    },
                    onDelete: (todo) async {
                      await _service.deleteTodo(todo.id);
                      _loadData();
                    },
                    onAssignTime: _showAssignTimeSheet,
                  ),
                ],

                // 흰 카드 (타임 그리드)
                Expanded(
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(24),
                        topRight: Radius.circular(24),
                      ),
                      boxShadow: [
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

  void _showAssignTimeSheet(TodoItem todo) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) =>
          _AssignTimeSheet(todo: todo, service: _service, onSaved: _loadData),
    );
  }
}

// ── 집중세션 토글 ────────────────────────────────────────────────────
class _FocusToggle extends StatelessWidget {
  final bool showFocus;
  final ValueChanged<bool> onChanged;

  const _FocusToggle({required this.showFocus, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
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
  final List<TodoItem> items;
  final Map<String, String> categoryColors;
  final ValueChanged<TodoItem> onToggle;
  final ValueChanged<TodoItem> onDelete;
  final ValueChanged<TodoItem> onAssignTime;

  const _UnscheduledSection({
    required this.items,
    required this.categoryColors,
    required this.onToggle,
    required this.onDelete,
    required this.onAssignTime,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE0E8FF)),
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
                  chipColor: categoryColors.containsKey(todo.categoryId)
                      ? _hexColor(categoryColors[todo.categoryId]!)
                      : _hexColor(todo.color),
                  onToggle: () => onToggle(todo),
                  onDelete: () => onDelete(todo),
                  onAssignTime: () => onAssignTime(todo),
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
  final TodoItem todo;
  final Color chipColor;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onAssignTime;

  const _UnscheduledTile({
    required this.todo,
    required this.chipColor,
    required this.onToggle,
    required this.onDelete,
    required this.onAssignTime,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      onLongPress: onAssignTime,
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
            if (todo.categoryId != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: chipColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  todo.categoryId!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: chipColor,
                  ),
                ),
              ),
            GestureDetector(
              onTap: onAssignTime,
              child: const Padding(
                padding: EdgeInsets.only(left: 10),
                child: Icon(Icons.schedule, size: 18, color: _kMain),
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
class _TimePickerButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _TimePickerButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hasValue = RegExp(r'^\d{2}:\d{2}$').hasMatch(label);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFCCCCCC)),
          borderRadius: BorderRadius.circular(10),
          color: hasValue ? const Color(0xFFEEF4FF) : Colors.white,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.access_time, size: 16, color: _kMain),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: hasValue ? _kMain : const Color(0xFF888888),
                fontWeight:
                    hasValue ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AssignTimeSheet extends StatefulWidget {
  final TodoItem todo;
  final TimetableService service;
  final VoidCallback onSaved;

  const _AssignTimeSheet(
      {required this.todo, required this.service, required this.onSaved});

  @override
  State<_AssignTimeSheet> createState() => _AssignTimeSheetState();
}

class _AssignTimeSheetState extends State<_AssignTimeSheet> {
  String? _startTime;
  String? _deadlineTime;

  @override
  void initState() {
    super.initState();
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickStart() async {
    final p =
        await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (p != null) setState(() => _startTime = _fmt(p));
  }

  Future<void> _pickDeadline() async {
    final p =
        await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (p != null) setState(() => _deadlineTime = _fmt(p));
  }

  Future<void> _save() async {
    if (_startTime == null) return;
    await widget.service.updateTodoTime(
        widget.todo.id, _startTime!, _deadlineTime);
    if (!mounted) return;
    Navigator.pop(context);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
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
          Text(
            widget.todo.content,
            style:
                const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          const Text(
            '시간을 지정하면 타임테이블에 표시됩니다',
            style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                  child: _TimePickerButton(
                      label: _startTime ?? '시작 시간 (필수)',
                      onTap: _pickStart)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('~', style: TextStyle(color: Colors.grey)),
              ),
              Expanded(
                  child: _TimePickerButton(
                      label: _deadlineTime ?? '마감 시간',
                      onTap: _pickDeadline)),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _startTime != null ? _save : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kMain,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                disabledBackgroundColor: const Color(0xFFCCCCCC),
              ),
              child: const Text(
                '타임테이블에 추가',
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
