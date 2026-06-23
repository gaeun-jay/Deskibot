
import 'package:flutter/material.dart';
import 'package:deskibot/models/todo_model.dart';
import 'package:deskibot/models/focus_block_model.dart';
import 'package:deskibot/services/timetable_service.dart';

// ── 색상 팔레트 ───────────────────────────────────────────────────

const List<String> _kPalette = [
  '#4A90D9', '#7B68EE', '#E74C3C', '#E67E22',
  '#F1C40F', '#27AE60', '#1ABC9C', '#EC407A',
  '#546E7A', '#8D6E63', '#8E24AA', '#607D8B',
];

Color _hexColor(String hex) =>
    Color(int.parse(hex.replaceFirst('#', '0xFF')));


String _minutesToTime(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

// ── 화면 ──────────────────────────────────────────────────────────

class TimetableScreen extends StatefulWidget {
  const TimetableScreen({super.key});

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  final _service = TimetableService();

  DateTime _selectedDate = DateTime.now();
  bool _showTodo = true;
  bool _showScheduled = true;   // 하위: 시간 지정 Todo → 타임테이블
  bool _showUnscheduled = true; // 하위: 시간 미지정 Todo → 상단 섹션
  bool _showFocus = true;

  List<TodoItem> _todos = [];
  List<FocusBlock> _focusBlocks = [];
  bool _isLoading = true;

  bool _wasVisible = false;

  @override
  void initState() {
    super.initState();
    _loadData();
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

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final todos = await _service.getTodosForDate(_dateKey);
    final blocks = await _service.getFocusBlocksForDate(_dateKey);
    if (!mounted) return;
    setState(() {
      _todos = todos;
      _focusBlocks = blocks;
      _isLoading = false;
    });
  }

  void _prevDay() {
    setState(() => _selectedDate = _selectedDate.subtract(const Duration(days: 1)));
    _loadData();
  }

  void _nextDay() {
    setState(() => _selectedDate = _selectedDate.add(const Duration(days: 1)));
    _loadData();
  }

  List<TodoItem> get _unscheduled => _todos.where((t) => !t.hasTime).toList();
  List<TodoItem> get _scheduled => _todos.where((t) => t.hasTime).toList();

  // ── 블록 레이아웃 계산 ─────────────────────────────────────────

  List<_BlockLayout> _buildLayouts() {
    final layouts = <_BlockLayout>[];

    if (_showTodo && _showScheduled) {
      for (final todo in _scheduled) {
        layouts.add(_BlockLayout(
          id: todo.id,
          title: todo.content,
          startMinutes: todo.startMinutes,
          endMinutes: todo.endMinutes,
          isFocus: false,
          isDone: todo.isDone,
          color: todo.color,
        ));
      }
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

  // ── 빌드 ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _Header(selectedDate: _selectedDate, onPrev: _prevDay, onNext: _nextDay),
            _FilterToggle(
              showTodo: _showTodo,
              showScheduled: _showScheduled,
              showUnscheduled: _showUnscheduled,
              showFocus: _showFocus,
              onTodoChanged: (v) => setState(() => _showTodo = v),
              onScheduledChanged: (v) => setState(() => _showScheduled = v),
              onUnscheduledChanged: (v) => setState(() => _showUnscheduled = v),
              onFocusChanged: (v) => setState(() => _showFocus = v),
            ),
            if (_unscheduled.isNotEmpty && _showTodo && _showUnscheduled)
              _UnscheduledSection(
                items: _unscheduled,
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
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF4A90D9)))
                  : _TimeGrid(
                      layouts: _buildLayouts(),
                      onFocusTap: _showEditFocusLabelSheet,
                      onTodoTap: _showTodoOptionsSheet,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditFocusLabelSheet(String sessionId, String currentLabel) {
    final ctrl = TextEditingController(text: currentLabel);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
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
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
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
                  backgroundColor: const Color(0xFF4A90D9),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('저장',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
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
              child: Text(
                title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFE74C3C)),
              title: const Text('삭제', style: TextStyle(color: Color(0xFFE74C3C))),
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AssignTimeSheet(todo: todo, service: _service, onSaved: _loadData),
    );
  }
}

// ── 헤더 ──────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final DateTime selectedDate;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  const _Header({required this.selectedDate, required this.onPrev, required this.onNext});

  String get _label {
    final now = DateTime.now();
    final isToday = selectedDate.year == now.year &&
        selectedDate.month == now.month &&
        selectedDate.day == now.day;
    final s = '${selectedDate.month}월 ${selectedDate.day}일';
    return isToday ? '$s (오늘)' : s;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: [
          const Text(
            '타임테이블',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF4A90D9)),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 22),
            onPressed: onPrev,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
          Text(_label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 22),
            onPressed: onNext,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// ── 필터 체크박스 ──────────────────────────────────────────────────

class _FilterToggle extends StatelessWidget {
  final bool showTodo;
  final bool showScheduled;
  final bool showUnscheduled;
  final bool showFocus;
  final ValueChanged<bool> onTodoChanged;
  final ValueChanged<bool> onScheduledChanged;
  final ValueChanged<bool> onUnscheduledChanged;
  final ValueChanged<bool> onFocusChanged;

  const _FilterToggle({
    required this.showTodo,
    required this.showScheduled,
    required this.showUnscheduled,
    required this.showFocus,
    required this.onTodoChanged,
    required this.onScheduledChanged,
    required this.onUnscheduledChanged,
    required this.onFocusChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // To-do 체크박스 + 하위 토글
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FilterCheckbox(
                label: 'To-do',
                color: const Color(0xFF4A90D9),
                checked: showTodo,
                onChanged: onTodoChanged,
              ),
              // 하위 토글: To-do 체크 시에만 표시
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                alignment: Alignment.topLeft,
                child: showTodo
                    ? Padding(
                        padding: const EdgeInsets.only(top: 6, left: 4),
                        child: Row(
                          children: [
                            _FilterCheckbox(
                              label: '시간 지정',
                              color: const Color(0xFF4A90D9),
                              checked: showScheduled,
                              onChanged: onScheduledChanged,
                              small: true,
                            ),
                            const SizedBox(width: 12),
                            _FilterCheckbox(
                              label: '시간 미지정',
                              color: const Color(0xFF4A90D9),
                              checked: showUnscheduled,
                              onChanged: onUnscheduledChanged,
                              small: true,
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          const SizedBox(width: 20),
          // 집중세션 체크박스
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _FilterCheckbox(
              label: '집중세션',
              color: const Color(0xFF7B68EE),
              checked: showFocus,
              onChanged: onFocusChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterCheckbox extends StatelessWidget {
  final String label;
  final Color color;
  final bool checked;
  final ValueChanged<bool> onChanged;
  final bool small;

  const _FilterCheckbox({
    required this.label,
    required this.color,
    required this.checked,
    required this.onChanged,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = small ? 16.0 : 20.0;
    final fontSize = small ? 11.0 : 13.0;
    return GestureDetector(
      onTap: () => onChanged(!checked),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: checked ? color : Colors.white,
              border: Border.all(
                color: checked ? color : const Color(0xFFCCCCCC),
                width: 1.8,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: checked
                ? Icon(Icons.check, color: Colors.white, size: size - 4)
                : null,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: checked ? color : const Color(0xFFAAAAAA),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 시간 미정 섹션 ─────────────────────────────────────────────────

class _UnscheduledSection extends StatelessWidget {
  final List<TodoItem> items;
  final ValueChanged<TodoItem> onToggle;
  final ValueChanged<TodoItem> onDelete;
  final ValueChanged<TodoItem> onAssignTime;

  const _UnscheduledSection({
    required this.items,
    required this.onToggle,
    required this.onDelete,
    required this.onAssignTime,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(18),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: const BoxDecoration(
              color: Color(0xFFD6E8FF),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: const Text(
              '하루 일정',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF333333),
              ),
            ),
          ),
          // 아이템 목록
          ...List.generate(items.length, (i) {
            final todo = items[i];
            return Column(
              children: [
                if (i > 0)
                  const Divider(height: 1, thickness: 1, indent: 16, endIndent: 16, color: Color(0xFFF0F0F0)),
                _UnscheduledTile(
                  todo: todo,
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
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onAssignTime;

  const _UnscheduledTile({
    required this.todo,
    required this.onToggle,
    required this.onDelete,
    required this.onAssignTime,
  });

  @override
  Widget build(BuildContext context) {
    final chipColor = _hexColor(todo.color);
    return GestureDetector(
      onTap: onToggle,
      onLongPress: () => _showDeleteConfirm(context),
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
                  color: todo.isDone ? const Color(0xFFAAAAAA) : Colors.black87,
                  decoration: todo.isDone ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            if (todo.categoryId != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: chipColor.withAlpha(36),
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
                child: Icon(Icons.schedule, size: 18, color: Color(0xFF4A90D9)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirm(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFE74C3C)),
              title: const Text('삭제', style: TextStyle(color: Color(0xFFE74C3C))),
              onTap: () {
                Navigator.pop(context);
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── 색상 팔레트 피커 ──────────────────────────────────────────────

class _ColorPicker extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelect;

  const _ColorPicker({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _kPalette.map((hex) {
        final color = _hexColor(hex);
        final isSelected = hex == selected;
        return GestureDetector(
          onTap: () => onSelect(hex),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: isSelected ? Border.all(color: Colors.black54, width: 2.5) : null,
            ),
            child: isSelected
                ? const Icon(Icons.check, color: Colors.white, size: 16)
                : null,
          ),
        );
      }).toList(),
    );
  }
}

// ── 타임 그리드 ───────────────────────────────────────────────────

class _TimeGrid extends StatelessWidget {
  final List<_BlockLayout> layouts;
  final void Function(String id, String label)? onFocusTap;
  final void Function(String id, String title)? onTodoTap;

  const _TimeGrid({required this.layouts, this.onFocusTap, this.onTodoTap});

  static const double _hourH = 80.0;
  static const double _labelW = 52.0;

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
                // 시간 레이블 + 구분선
                ...List.generate(24, (h) {
                  final y = h * _hourH;
                  return Stack(children: [
                    Positioned(
                      top: y - 9,
                      left: 0,
                      width: _labelW - 6,
                      child: Text(
                        '${h.toString().padLeft(2, '0')}:00',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 11, color: Color(0xFFAAAAAA)),
                      ),
                    ),
                    Positioned(
                      top: y,
                      left: _labelW,
                      width: gridW,
                      height: 1,
                      child: const ColoredBox(color: Color(0xFFEEEEEE)),
                    ),
                  ]);
                }),

                // 블록들
                ...layouts.map((l) {
                  final top = l.startMinutes * _hourH / 60;
                  final height =
                      ((l.endMinutes - l.startMinutes) * _hourH / 60).clamp(24.0, double.infinity);
                  final colW = gridW / l.totalColumns;
                  final left = _labelW + l.column * colW + 2;

                  final Color accent;
                  final Color bg;
                  final Color textC;

                  if (l.isFocus) {
                    accent = const Color(0xFF4A90D9);
                    bg = const Color(0xFFE3F2FF);
                    textC = const Color(0xFF1565C0);
                  } else {
                    accent = _hexColor(l.color);
                    bg = accent.withAlpha(28);
                    textC = accent;
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
                        clipBehavior: Clip.hardEdge,
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border(left: BorderSide(color: accent, width: 4)),
                        ),
                        padding: EdgeInsets.fromLTRB(
                          10,
                          height < 30 ? 4 : 8,
                          8,
                          height < 30 ? 2 : 6,
                        ),
                        child: height < 18
                            ? const SizedBox.shrink()
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      l.title,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: textC,
                                        decoration: l.isDone
                                            ? TextDecoration.lineThrough
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
                                        color: textC.withAlpha(180),
                                      ),
                                    ),
                                ],
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

// ── 시간 선택 버튼 ─────────────────────────────────────────────────

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
            const Icon(Icons.access_time, size: 16, color: Color(0xFF4A90D9)),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: hasValue ? const Color(0xFF4A90D9) : const Color(0xFF888888),
                fontWeight: hasValue ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 내부 블록 레이아웃 데이터 ─────────────────────────────────────

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

// ── 시간 지정 바텀시트 (미정 Todo → 타임테이블 이동) ──────────────

class _AssignTimeSheet extends StatefulWidget {
  final TodoItem todo;
  final TimetableService service;
  final VoidCallback onSaved;

  const _AssignTimeSheet({required this.todo, required this.service, required this.onSaved});

  @override
  State<_AssignTimeSheet> createState() => _AssignTimeSheetState();
}

class _AssignTimeSheetState extends State<_AssignTimeSheet> {
  String? _startTime;
  String? _deadlineTime;
  late String _color;

  @override
  void initState() {
    super.initState();
    _color = widget.todo.color;
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickStart() async {
    final p = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (p != null) setState(() => _startTime = _fmt(p));
  }

  Future<void> _pickDeadline() async {
    final p = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (p != null) setState(() => _deadlineTime = _fmt(p));
  }

  Future<void> _save() async {
    if (_startTime == null) return;

    await widget.service.updateTodoTime(widget.todo.id, _startTime!, _deadlineTime);
    if (_color != widget.todo.color) {
      await widget.service.updateTodoColor(widget.todo.id, _color);
    }

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
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
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
              Expanded(child: _TimePickerButton(label: _startTime ?? '시작 시간 (필수)', onTap: _pickStart)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('~', style: TextStyle(color: Colors.grey)),
              ),
              Expanded(child: _TimePickerButton(label: _deadlineTime ?? '마감 시간', onTap: _pickDeadline)),
            ],
          ),
          const SizedBox(height: 14),
          const Text('색상', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF555555))),
          const SizedBox(height: 8),
          _ColorPicker(selected: _color, onSelect: (h) => setState(() => _color = h)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _startTime != null ? _save : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _hexColor(_color),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                disabledBackgroundColor: const Color(0xFFCCCCCC),
              ),
              child: const Text(
                '타임테이블에 추가',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
