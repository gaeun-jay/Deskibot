import 'dart:async';

import 'package:flutter/material.dart';
import 'package:deskibot/models/focus_session_model.dart';
import 'package:deskibot/models/todo_model.dart';
import 'package:deskibot/models/user_model.dart';
import 'package:deskibot/services/api_client.dart';
import 'package:deskibot/services/auth_service.dart';
import 'package:deskibot/services/focus_session_service.dart';
import 'package:deskibot/services/todo_service.dart';
import 'package:deskibot/services/user_service.dart';
import 'package:deskibot/screens/auth/login_screen.dart';
import 'package:deskibot/theme/app_styles.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Category> _categories = [];
  late final Stream<List<TodoModel>> _todosStream;
  late final Stream<List<FocusSessionModel>> _focusSessionsStream;

  bool _showForm = false;
  String? _editingTodoId;
  final _contentController = TextEditingController();
  String? _selectedCategoryId;

  /// 할 일 카드가 지금 보여주고 있는 날짜. 카드 제목 줄의 화살표로 옮긴다.
  /// 헤더의 날짜와 아래 "오늘의 집중 현황"은 여기에 따라오지 않고 늘 오늘이다.
  DateTime _viewingDay = _dayOnly(DateTime.now());

  /// 추가/수정 폼 안에서 고르는 날짜. 폼을 열면 [_viewingDay] 로 시작한다.
  DateTime _selectedDate = _dayOnly(DateTime.now());
  TimeOfDay? _selectedDeadlineTime;
  String _notifyOption = '없음';
  StreamSubscription<List<Category>>? _categoriesSub;

  @override
  void initState() {
    super.initState();
    _todosStream = TodoService().getTodayTodos();
    _focusSessionsStream = FocusSessionService().getTodaySessions();
    // 설정 화면에서 카테고리를 추가/수정/삭제(색상 변경 포함)해도 곧바로
    // 반영되도록, 싱글톤 UserService 의 브로드캐스트 스트림을 계속 구독한다.
    _categoriesSub = UserService().watchCategories().listen((categories) {
      if (mounted) setState(() => _categories = categories);
    });
  }

  @override
  void dispose() {
    _contentController.dispose();
    _categoriesSub?.cancel();
    super.dispose();
  }

  Color _categoryColor(String hex) {
    return Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));
  }

  /// 배경색 밝기에 따라 잘 보이는 글자색(흰색/검정)을 고른다.
  /// 연한 파스텔 카테고리 색 위에 흰 글씨가 묻히는 걸 막기 위함.
  Color _onColor(Color background) {
    return background.computeLuminance() > 0.5
        ? const Color(0xFF1E1E1E)
        : Colors.white;
  }

  String _formatTodayHeader() {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    final now = DateTime.now();
    return '${now.year}년 ${now.month}월 ${now.day}일 ${weekdays[now.weekday - 1]}요일';
  }

  String _formatDate(DateTime date) {
    return '${date.year}. ${date.month.toString().padLeft(2, '0')}. ${date.day.toString().padLeft(2, '0')}.';
  }

  String _dateToStr(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// 시/분을 떼고 날짜만 남긴다. 날짜끼리 비교하려면 이게 필요하다.
  static DateTime _dayOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  bool _isToday(DateTime day) => _dayOnly(day) == _dayOnly(DateTime.now());

  /// 할 일 카드 제목 줄에 쓰는 표기. 예: "8월 22일 (금)"
  String _formatViewingDay() {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    return '${_viewingDay.month}월 ${_viewingDay.day}일 '
        '(${weekdays[_viewingDay.weekday - 1]})';
  }

  /// 할 일 카드를 다른 날짜로 옮긴다.
  ///
  /// TodoService 는 싱글톤이고 마지막으로 불러온 날짜를 기억하므로, 여기서
  /// refresh 만 해두면 이후의 추가·수정·삭제·체크가 전부 이 날짜 기준으로
  /// 다시 불러와진다.
  Future<void> _goToDay(DateTime day) async {
    final target = _dayOnly(day);
    final previous = _viewingDay;
    setState(() {
      _viewingDay = target;
      // 폼이 열려 있으면 같이 옮긴다. 추가한 게 바로 이 목록에 뜨도록.
      // 수정 중일 때는 그 할 일의 날짜를 건드리면 안 되니 놔둔다.
      if (_showForm && _editingTodoId == null) _selectedDate = target;
    });

    try {
      await TodoService().refresh(date: _dateToStr(target));
    } on ApiException catch (e) {
      // 못 불러왔으면 원래 날짜로 되돌린다. 안 그러면 도착하지 않을 목록을
      // 기다리며 로딩 표시가 계속 돈다.
      if (!mounted) return;
      setState(() => _viewingDay = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.userMessage)),
      );
    }
  }

  Future<void> _shiftDay(int days) =>
      _goToDay(_viewingDay.add(Duration(days: days)));

  Future<void> _pickViewingDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _viewingDay,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked != null) await _goToDay(picked);
  }

  String _timeStr(TimeOfDay? time) {
    if (time == null) return '--:--';
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  TimeOfDay? _parseTime(String? hhmm) {
    if (hhmm == null) return null;
    final parts = hhmm.split(':');
    return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  Future<void> _pickDeadlineTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedDeadlineTime ?? TimeOfDay.now(),
    );
    if (picked != null) setState(() => _selectedDeadlineTime = picked);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  void _openForm() => setState(() {
        _showForm = true;
        // 지금 보고 있는 날짜로 시작한다. 폼 안에서 다른 날짜로 바꿔도 된다.
        _selectedDate = _viewingDay;
      });

  void _closeForm() {
    _contentController.clear();
    setState(() {
      _showForm = false;
      _editingTodoId = null;
      _selectedCategoryId = null;
      _selectedDate = _viewingDay;
      _selectedDeadlineTime = null;
      _notifyOption = '없음';
    });
  }

  void _startEdit(TodoModel todo) {
    _contentController.text = todo.content;
    final dateParts = todo.date.split('-');
    setState(() {
      _showForm = true;
      _editingTodoId = todo.id;
      _selectedCategoryId = todo.categoryId;
      _selectedDate = DateTime(
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(dateParts[2]),
      );
      _selectedDeadlineTime = _parseTime(todo.deadlineTime);
      if (!todo.notify) {
        _notifyOption = '없음';
      } else if (todo.notifyBefore == 60) {
        _notifyOption = '마감 1시간 전';
      } else {
        _notifyOption = '마감 30분 전';
      }
    });
  }

  Future<void> _showTodoActions(TodoModel todo) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'edit'),
            child: const Text('수정'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (action == 'edit') {
      _startEdit(todo);
    } else if (action == 'delete') {
      await _showDeleteDialog(todo.id);
    }
  }

  Future<void> _addTodo() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('할일 내용을 입력해주세요')),
      );
      return;
    }
    if (_selectedCategoryId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('카테고리를 선택해주세요')),
      );
      return;
    }
    final deadlineBase = _selectedDeadlineTime;

    if (_notifyOption != '없음' && deadlineBase == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('마감 시간을 선택해주세요')),
      );
      return;
    }

    final deadlineTime = deadlineBase == null ? null : _timeStr(deadlineBase);
    bool notify = false;
    int? notifyBefore;

    if (_notifyOption == '마감 1시간 전') {
      notify = true;
      notifyBefore = 60;
    } else if (_notifyOption == '마감 30분 전') {
      notify = true;
      notifyBefore = 30;
    }

    final todo = TodoModel(
      id: '',
      content: content,
      categoryId: _selectedCategoryId,
      date: _dateToStr(_selectedDate),
      notify: notify,
      deadlineTime: deadlineTime,
      notifyBefore: notifyBefore,
      isDone: false,
    );

    if (_editingTodoId == null) {
      await TodoService().addTodo(todo);
    } else {
      await TodoService().updateTodo(_editingTodoId!, todo);
    }
    if (!mounted) return;

    // 보고 있는 날짜가 아닌 다른 날짜로 저장했으면 그 날짜로 옮겨준다.
    // 안 그러면 방금 넣은 할 일이 목록에 없어서 저장이 안 된 것처럼 보인다.
    final savedDay = _dayOnly(_selectedDate);
    if (savedDay != _viewingDay) {
      await _goToDay(savedDay);
      if (!mounted) return;
    }

    _closeForm();
  }

  Future<void> _showDeleteDialog(String todoId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('할일 삭제'),
        content: const Text('이 할일을 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) await TodoService().deleteTodo(todoId);
  }

  Future<void> _onLogout() async {
    await AuthService().logout();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: kAppBackgroundGradient),
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  children: [
                    if (_showForm) ...[
                      _buildForm(),
                      const SizedBox(height: 12),
                    ],
                    _buildTodoList(),
                    const SizedBox(height: 12),
                    _buildFocusStats(),
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/images/Launcher_icon.png',
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Deskibot',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _onLogout,
                  child: const Icon(
                    Icons.logout,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('일정 관리', style: kHeaderTitleStyle),
                    const SizedBox(height: 2),
                    const Text(
                      '오늘의 할일을 정리하고 하루를 시작하세요.',
                      style: kHeaderSubtitleStyle,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatTodayHeader(),
                      style: kHeaderSubtitleStyle.copyWith(
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Image.asset(
                  'assets/images/Home_character.png',
                  width: kHeaderCharacterSize,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.smart_toy,
                    size: kHeaderCharacterSize,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _showForm ? _closeForm() : _openForm(),
                icon: Icon(
                  _showForm ? Icons.close : Icons.add,
                  color: Colors.white,
                  size: 20,
                ),
                label: Text(
                  _showForm ? '닫기' : '할일 추가하기',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0x4D0073FF),
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _formLabel('할일'),
          const SizedBox(height: 8),
          TextField(
            controller: _contentController,
            decoration: InputDecoration(
              hintText: '할일을 입력하세요',
              hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF0069FF)),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
          const SizedBox(height: 16),
          _formLabel('카테고리'),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _categories.map((cat) {
                final selected = _selectedCategoryId == cat.id;
                final color = _categoryColor(cat.color);
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => setState(() {
                      _selectedCategoryId = selected ? null : cat.id;
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? color : Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected ? color : const Color(0xFFDDDDDD),
                        ),
                      ),
                      child: Text(
                        cat.name,
                        style: TextStyle(
                          color: selected ? _onColor(color) : const Color(0xFF9AA0A6),
                          fontSize: 13,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
          // 할 일은 체크리스트 형식이라 시작·종료 시각이 없다. 마감만 선택.
          _timeRow('마감 시간 (선택)', _timeStr(_selectedDeadlineTime),
              _pickDeadlineTime),
          const SizedBox(height: 12),
          _dateRow(),
          const SizedBox(height: 12),
          _notifyRow(),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                flex: 1,
                child: OutlinedButton(
                  onPressed: _closeForm,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFFDDDDDD)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: const Text('취소', style: TextStyle(color: Colors.grey)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: ElevatedButton(
                  onPressed: _addTodo,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0069FF),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    _editingTodoId == null ? '추가하기' : '수정하기',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _formLabel(String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: 13, color: Colors.black54, fontWeight: FontWeight.w500),
    );
  }

  Widget _timeRow(String label, String value, VoidCallback onTap) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 14, color: Colors.black54)),
        GestureDetector(
          onTap: onTap,
          child: Row(
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  color: value == '--:--' ? Colors.grey : Colors.black87,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.access_time, size: 18, color: Colors.grey),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dateRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('날짜', style: TextStyle(fontSize: 14, color: Colors.black54)),
        GestureDetector(
          onTap: _pickDate,
          child: Row(
            children: [
              Text(
                _formatDate(_selectedDate),
                style: const TextStyle(fontSize: 14, color: Colors.black87),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.calendar_today, size: 18, color: Colors.grey),
            ],
          ),
        ),
      ],
    );
  }

  Widget _notifyRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('알림', style: TextStyle(fontSize: 14, color: Colors.black54)),
        DropdownButton<String>(
          value: _notifyOption,
          underline: const SizedBox(),
          style: const TextStyle(fontSize: 13, color: Colors.black87),
          items: const [
            DropdownMenuItem(value: '없음', child: Text('없음')),
            DropdownMenuItem(value: '마감 1시간 전', child: Text('마감 1시간 전')),
            DropdownMenuItem(value: '마감 30분 전', child: Text('마감 30분 전')),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _notifyOption = v);
          },
        ),
      ],
    );
  }

  Widget _buildTodoList() {
    return StreamBuilder<List<TodoModel>>(
      stream: _todosStream,
      builder: (context, snapshot) {
        final todos = snapshot.data ?? [];
        // 스트림은 싱글톤에 하나뿐이라, 날짜를 옮기는 동안에는 아직 이전
        // 날짜의 목록이 흐르고 있다. 제목은 새 날짜인데 목록은 옛 날짜인
        // 상태를 보여주지 않도록, 도착할 때까지 자리만 잡아둔다.
        final isCurrent = TodoService().loadedDate == _dateToStr(_viewingDay);
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildTodoListHeader(isCurrent ? todos.length : null),
              const SizedBox(height: 12),
              if (!isCurrent)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (todos.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      _isToday(_viewingDay)
                          ? '오늘 할일이 없습니다'
                          : '이 날은 할일이 없습니다',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              else
                ...todos.map(_buildTodoItem),
            ],
          ),
        );
      },
    );
  }

  /// 할 일 카드 제목 줄. "◀ 8월 22일 (금) ▶ [오늘] [전체 3]"
  ///
  /// [count] 가 null 이면 아직 그 날짜 목록이 도착하지 않은 상태다.
  Widget _buildTodoListHeader(int? count) {
    return Row(
      children: [
        // 화살표·날짜는 남는 폭을 나눠 쓰고, 좁으면 날짜가 줄어든다.
        // 오른쪽 칩들은 항상 제 크기를 지킨다.
        Expanded(
          child: Row(
            children: [
              Image.asset(
                'assets/images/todoboard.png',
                width: 24,
                height: 24,
              ),
              const SizedBox(width: 2),
              _buildDayArrow(Icons.chevron_left, () => _shiftDay(-1)),
              Flexible(
                child: GestureDetector(
                  onTap: _pickViewingDay,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 4,
                    ),
                    child: Text(
                      _formatViewingDay(),
                      style: kCardTitleStyle,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              _buildDayArrow(Icons.chevron_right, () => _shiftDay(1)),
            ],
          ),
        ),
        if (!_isToday(_viewingDay)) ...[
          // 채워진 파란 칩으로 두면 "지금 보고 있는 날이 오늘"이라는 상태 표시처럼
          // 읽힌다. 되돌아가기 화살표 + "오늘로" 로 눌러야 할 버튼임을 분명히 한다.
          GestureDetector(
            onTap: () => _goToDay(DateTime.now()),
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF0069FF)),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.undo, size: 13, color: Color(0xFF0069FF)),
                  SizedBox(width: 3),
                  Text(
                    '오늘로',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF0069FF),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFEEF4FF),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '전체 ${count ?? '-'}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF0069FF)),
          ),
        ),
      ],
    );
  }

  Widget _buildDayArrow(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 20, color: const Color(0xFF6286B8)),
      ),
    );
  }

  Widget _buildTodoItem(TodoModel todo) {
    final category =
        _categories.where((c) => c.id == todo.categoryId).firstOrNull;

    return GestureDetector(
      onLongPress: () => _showTodoActions(todo),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => TodoService().toggleTodo(todo.id, !todo.isDone),
              child: Icon(
                todo.isDone
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: todo.isDone
                    ? const Color(0xFF0069FF)
                    : const Color(0xFFCCCCCC),
                size: 22,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                todo.content,
                style: TextStyle(
                  fontSize: 14,
                  decoration: todo.isDone ? TextDecoration.lineThrough : null,
                  color: todo.isDone ? Colors.grey : Colors.black87,
                ),
              ),
            ),
            if (todo.deadlineTime != null) ...[
              const SizedBox(width: 6),
              Row(
                children: [
                  const Icon(Icons.access_time, size: 12, color: Colors.red),
                  const SizedBox(width: 2),
                  Text(
                    todo.deadlineTime!,
                    style: const TextStyle(fontSize: 12, color: Colors.red),
                  ),
                ],
              ),
            ],
            if (category != null) ...[
              const SizedBox(width: 6),
              Builder(builder: (_) {
                final color = _categoryColor(category.color);
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    category.name,
                    style: TextStyle(fontSize: 11, color: color),
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  (String, String) _formatFocusDuration(int totalMinutes) {
    if (totalMinutes <= 0) return ('0', 'm');
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours <= 0) return (minutes.toString(), 'm');
    return (hours.toString(), 'h ${minutes}m');
  }

  Widget _buildFocusStats() {
    return StreamBuilder<List<FocusSessionModel>>(
      stream: _focusSessionsStream,
      builder: (context, snapshot) {
        final sessions = snapshot.data ?? [];
        final totalDuration =
            sessions.fold<int>(0, (sum, s) => sum + s.actualDuration);
        final drowsyCount =
            sessions.fold<int>(0, (sum, s) => sum + s.drowsyEventCount);
        final drowsyDuration =
            sessions.fold<int>(0, (sum, s) => sum + s.drowsyDuration);
        final phoneCount =
            sessions.fold<int>(0, (sum, s) => sum + s.phoneEventCount);
        final phoneDuration =
            sessions.fold<int>(0, (sum, s) => sum + s.phoneDuration);
        final (focusValue, focusUnit) = _formatFocusDuration(totalDuration);
        final focusRate = totalDuration <= 0
            ? '-'
            : (((totalDuration - drowsyDuration - phoneDuration) /
                            totalDuration) *
                        100)
                    .clamp(0, 100)
                    .round()
                    .toString();

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Image.asset(
                    'assets/images/firewatch.png',
                    width: 24,
                    height: 24,
                  ),
                  const SizedBox(width: 6),
                  const Text('오늘의 집중 현황', style: kCardTitleStyle),
                ],
              ),
              const SizedBox(height: 10),
              if (sessions.isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('아직 오늘의 세션이 없어요',
                        style: TextStyle(color: Colors.grey)),
                  ),
                )
              else
                Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _StatCard(
                            label: '집중 시간',
                            value: focusValue,
                            unit: focusUnit,
                            bgColor: const Color(0xFFDEEBFF),
                            accentColor: const Color(0xFF0069FF),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatCard(
                            label: '집중률',
                            value: focusRate,
                            unit: focusRate == '-' ? '' : '%',
                            bgColor: const Color(0xFFDEEBFF),
                            accentColor: const Color(0xFF0069FF),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _StatCard(
                            label: '졸음 감지',
                            value: drowsyCount.toString(),
                            unit: '회',
                            bgColor: const Color(0xFFFFF0D6),
                            accentColor: const Color(0xFFBF5A00),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatCard(
                            label: '스마트폰 사용',
                            value: phoneCount.toString(),
                            unit: '회',
                            bgColor: const Color(0xFFFFE0E0),
                            accentColor: const Color(0xFFB71D28),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color bgColor;
  final Color accentColor;

  const _StatCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.bgColor,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: accentColor,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: value,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: accentColor,
                      height: 1.0,
                    ),
                  ),
                  TextSpan(
                    text: unit,
                    style: const TextStyle(
                      fontSize: 16,
                      color: Color(0xFF8E8E8E),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
