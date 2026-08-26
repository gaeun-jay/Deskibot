import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:deskibot/models/daily_model.dart';
import 'package:deskibot/services/daily_service.dart';
import 'package:deskibot/services/todo_service.dart';
import 'package:deskibot/services/focus_session_service.dart';
import 'package:deskibot/services/focus_websocket_service.dart';
import 'package:deskibot/models/todo_model.dart';
import 'package:deskibot/theme/app_styles.dart';

class DailyAnalysisScreen extends StatefulWidget {
  const DailyAnalysisScreen({super.key});

  @override
  State<DailyAnalysisScreen> createState() => _DailyAnalysisScreenState();
}

class _DailyAnalysisScreenState extends State<DailyAnalysisScreen> {
  int _selectedTab = 0;
  int _todoRate = 0;
  int _todoTotal = 0;
  int _todoDone = 0;
  DailyModel? _dailyData;
  Map<String, int> _timeSlotRates = {};
  int _focusRate = 0;
  int _totalScore = 0;
  int _totalMin = 0;
  String? _advice;
  String? _journalTitle;
  String? _journalSubtitle;
  String? _latestDrowsyTime;
  int _latestDrowsyDuration = 0;
  String? _latestPhoneTime;
  int _latestPhoneDuration = 0;
  late String _today;
  StreamSubscription<List<TodoModel>>? _todoSub;
  StreamSubscription<Map<String, dynamic>>? _wsSub;
  Timer? _dateCheckTimer;
  bool _wasVisible = false;

  // 공부일지 탭 전용. "분석" 탭(오늘 실시간)과 달리 전날(어제) 하루치 스냅샷이다.
  DailyModel? _journalData;
  List<TodoModel> _journalTodos = [];

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String _yesterdayStr() {
    final now = DateTime.now().subtract(const Duration(days: 1));
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  int get _h => _totalMin ~/ 60;
  int get _m => _totalMin % 60;

  int get _journalTotalMin =>
      (_journalData?.pomodoroDuration ?? 0) + (_journalData?.stopwatchDuration ?? 0);
  int get _journalH => _journalTotalMin ~/ 60;
  int get _journalM => _journalTotalMin % 60;
  int get _journalTodoTotal => _journalTodos.length;
  int get _journalTodoDone => _journalTodos.where((t) => t.isDone).length;

  @override
  void initState() {
    super.initState();
    _loadDailyData();
    // 홈 화면 등 다른 곳에서 투두를 추가/완료 처리해도 곧바로 반영되도록 함
    //
    // TodoService 의 스트림은 싱글톤에 하나뿐이라, 홈에서 화살표로 다른
    // 날짜를 보면 그 날짜의 목록이 여기로도 흘러들어온다. 이 화면의 수치는
    // "오늘"이어야 하므로, 오늘 것이 아니면 오늘 것을 따로 불러온다.
    _todoSub = TodoService().getTodayTodos().listen((todos) {
      if (TodoService().loadedDate == _todayStr()) {
        _onTodosUpdated(todos);
      } else {
        _reloadTodayTodos();
      }
    });

    // 로봇이 졸음/폰 사용을 감지해 끝날 때(detection_end)마다 통계를 다시 불러옴
    FocusWebSocketService.instance.connect();
    _wsSub = FocusWebSocketService.instance.stream.listen((msg) {
      if (msg['type'] == 'detection_event' && msg['action'] == 'detection_end') {
        _refreshStats();
      }
    });

    // 이 화면은 계속 떠 있을 수 있어서(IndexedStack), 자정을 넘겨도 아무 탭
    // 전환·이벤트 없이 계속 보고 있으면 날짜가 안 바뀔 수 있다. 1분마다
    // 스스로 날짜가 바뀌었는지 확인해서, 바뀌었으면 전부 다시 불러온다.
    _dateCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_todayStr() != _today) {
        _refreshStats();
        _refreshJournal();
        _refreshJournalData();
      }
    });
  }

  @override
  void dispose() {
    _todoSub?.cancel();
    _wsSub?.cancel();
    _dateCheckTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 하단 탭은 IndexedStack 이라 화면이 살아있는 채로 가려질 뿐이고,
    // 다시 눌러도 initState 가 돌지 않는다. 집중 화면에서 세션을 끝내고
    // 이 탭으로 오면 종료 전 수치가 그대로 보이므로, 다시 보이는 순간을
    // 잡아서 전부 새로 불러온다. (데일리로그 화면과 같은 방식)
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_wasVisible) _loadDailyData();
    _wasVisible = visible;
  }

  /// 스트림에 흐른 목록이 오늘 것이 아닐 때, 오늘 것만 따로 불러와 수치를 맞춘다.
  Future<void> _reloadTodayTodos() async {
    try {
      _onTodosUpdated(await TodoService().getTodosForDate(_todayStr()));
    } catch (_) {
      // 통계 갱신 실패로 화면이 깨질 이유는 없다. 다음 이벤트에 다시 시도한다.
    }
  }

  void _onTodosUpdated(List<TodoModel> todos) {
    if (!mounted) return;
    final total = todos.length;
    final done = todos.where((t) => t.isDone).length;
    final rate = total > 0 ? ((done / total) * 100).round() : 0;
    setState(() {
      _todoTotal = total;
      _todoDone = done;
      _todoRate = rate;
      _totalScore = ((_focusRate + rate) / 2).round();
    });
  }

  int _timeToMinutes(String time) {
    final parts = time.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  Future<void> _loadDailyData() async {
    await _refreshJournal();
    await _refreshJournalData();
    await _refreshStats();
  }

  /// 공부일지 탭에 보이는 어제 하루치 통계·할일을 불러온다.
  Future<void> _refreshJournalData() async {
    final yesterday = _yesterdayStr();
    final data = await DailyService().getTodayData(date: yesterday);
    final todos = await TodoService().getTodosForDate(yesterday);
    if (!mounted) return;
    setState(() {
      _journalData = data;
      _journalTodos = todos;
    });
  }

  /// 오늘의 공부일지(title/subtitle/advice)를 서버에서 다시 불러온다.
  /// DB 값이 바뀌어도(예: 재생성) 화면이 그 값을 다시 읽어오도록 탭을 열 때마다 호출한다.
  Future<void> _refreshJournal() async {
    var analysis = await DailyService().getTodayAnalysis();
    if (analysis == null) {
      try {
        analysis = await DailyService().generateTodayAnalysis();
      } catch (_) {
        analysis = null;
      }
    }
    if (!mounted) return;
    setState(() {
      // 생성 실패(그날 활동 없음 등)면 이전 날짜의 값이 남아있지 않도록 비운다.
      _journalTitle = analysis?['title'];
      _journalSubtitle = analysis?['subtitle'];
      _advice = analysis?['advice'];
    });
  }

  /// 졸음/폰 감지·집중 시간 통계를 불러옴
  Future<void> _refreshStats() async {
    final data = await DailyService().getTodayData();
    if (!mounted) return;

    // 시간대별 집중도
    _today = _todayStr();
    final sessions = await FocusSessionService().getSessionsByDate(_today);
    if (!mounted) return;
    final Map<String, int> rates = {};
    final slots = {
      '새벽': {'start': 0, 'end': 359, 'total': 360},
      '오전': {'start': 360, 'end': 719, 'total': 360},
      '점심': {'start': 720, 'end': 839, 'total': 120},
      '오후': {'start': 840, 'end': 1079, 'total': 240},
      '저녁': {'start': 1080, 'end': 1439, 'total': 360},
    };
    for (final entry in slots.entries) {
      final slotStart = entry.value['start']!;
      final slotEnd = entry.value['end']!;
      final slotTotal = entry.value['total']!;
      int sum = 0;
      for (final s in sessions) {
        final startMin = _timeToMinutes(s.endTime);
        if (startMin >= slotStart && startMin <= slotEnd) {
          sum += s.actualDuration;
        }
      }
      rates[entry.key] = (sum / slotTotal * 100).clamp(0, 100).round();
    }
    setState(() {
      _dailyData = data;
      _timeSlotRates = rates;
      _totalMin = (data?.pomodoroDuration ?? 0) + (data?.stopwatchDuration ?? 0);
      final drowsy = data?.drowsyDuration ?? 0;
      final phone = data?.phoneDuration ?? 0;
      _focusRate = _totalMin > 0 ? ((_totalMin - drowsy - phone) / _totalMin * 100).round() : 0;
      _totalScore = ((_focusRate + _todoRate) / 2).round();
      // 전체 세션 중 가장 최신 졸음/폰 이벤트 (start_time 기준)
      final drowsySessions = sessions
          .where((s) => s.latestDrowsyTime != null)
          .toList()
        ..sort((a, b) => a.latestDrowsyTime!.compareTo(b.latestDrowsyTime!));
      final phoneSessions = sessions
          .where((s) => s.latestPhoneTime != null)
          .toList()
        ..sort((a, b) => a.latestPhoneTime!.compareTo(b.latestPhoneTime!));
      _latestDrowsyTime = drowsySessions.isNotEmpty ? drowsySessions.last.latestDrowsyTime : null;
      _latestDrowsyDuration = drowsySessions.isNotEmpty ? drowsySessions.last.latestDrowsyDuration : 0;
      _latestPhoneTime = phoneSessions.isNotEmpty ? phoneSessions.last.latestPhoneTime : null;
      _latestPhoneDuration = phoneSessions.isNotEmpty ? phoneSessions.last.latestPhoneDuration : 0;
    });
  }

  String _getFormattedDate({int daysOffset = 0}) {
    final now = DateTime.now().add(Duration(days: daysOffset));
    const weekdays = ['월요일', '화요일', '수요일', '목요일', '금요일', '토요일', '일요일'];
    final weekday = weekdays[now.weekday - 1];
    return '${now.year}년 ${now.month}월 ${now.day}일 $weekday';
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
                padding: const EdgeInsets.only(bottom: 24),
                child: Column(
                  children: [
                    if (_selectedTab == 0) ...[
                      _buildScoreCard(_focusRate, _totalScore),
                      _buildKeywordSummary(_focusRate),
                      _buildTodoCard(),
                      _buildTimeSlotCard(),
                      _buildDisturbanceCard()
                    ] else ...[
                      _buildInfoBanner(),
                      _buildDailyJournalCard(),
                    ],
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
    return Container(
      width: double.infinity,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            children: [
              const SizedBox(height: 24),
              _buildCharacter(),
              const Text('일간 분석', style: kHeaderTitleStyle),
              const SizedBox(height: 4),
              Text(_getFormattedDate(), style: kHeaderSubtitleStyle),
              const SizedBox(height: 16),
              _buildTabButtons(),
            ],
          ),
        ),
      ),
    );
  }

  // 상단 비버 이미지
  Widget _buildCharacter() {
    return Image.asset(
      'assets/images/daily_character.png',
      width: kHeaderCharacterSize,
      height: kHeaderCharacterSize,
    );
  }

  // 상단 버튼
  Widget _buildTabButtons() {
    return GlassmorphicContainer(
      width: double.infinity,
      height: 60,
      borderRadius: 30,
      blur: 20,
      alignment: Alignment.center,
      border: 2,
      linearGradient: LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0.3),
          Colors.white.withValues(alpha: 0.2),
        ],
      ),
      borderGradient: LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0.4),
          Colors.white.withValues(alpha: 0.3),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          children: [
            _buildTabItem(index: 0, label: '분석'),
            const SizedBox(width: 8),
            _buildTabItem(index: 1, label: '공부일지'),
          ],
        ),
      ),
    );
  }

  Widget _buildTabItem({required int index, required String label}) {
    final isSelected = _selectedTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _selectedTab = index);
          // 공부일지 탭을 열 때마다 DB 최신 값을 다시 불러온다.
          if (index == 1) {
            _refreshJournal();
            _refreshJournalData();
          }
        },
        child: GlassmorphicContainer(
          width: double.infinity,
          height: double.infinity,
          borderRadius: 26,
          blur: 15,
          border: 1.5,
          linearGradient: LinearGradient(
            colors: isSelected
                ? [
                    const Color(0xFF5097FF).withValues(alpha: 0.9),
                    const Color(0xFF5097FF).withValues(alpha: 0.7),
                  ]
                : [
                    const Color(0xFFA7A7A7).withValues(alpha: 0.25),
                    const Color(0xFFA7A7A7).withValues(alpha: 0.20),
                  ],
          ),
          borderGradient: LinearGradient(
            colors: [
              Colors.white.withValues(alpha: 0.4),
              Colors.white.withValues(alpha: 0.6),
            ],
          ),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // 오늘의 종합 점수
  Widget _buildScoreCard(int focusRate, int totalScore) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: const Color(0xFFD1D1D1),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('오늘의 종합 점수', style: kCardTitleStyle),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 120,
                height: 120,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(120, 120),
                      painter: RoundedArcPainter(
                        progress: totalScore / 100,
                        activeColor: const Color(0xFF009AFF),
                        backgroundColor: const Color(0xFFF0F0F0),
                        strokeWidth: 12,
                      ),
                    ),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: '$totalScore',
                            style: TextStyle(
                              fontSize: 40,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                          TextSpan(
                            text: '점',
                            style: TextStyle(
                              fontSize: 14,
                              color: Color(0xFF8E8E8E),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  children: [
                    _buildScoreItem('집중률', focusRate, const Color(0xFF009AFF)),
                    const Divider(height: 24, color: Color(0xFFDFDFDF)),
                    _buildScoreItem('Todo 달성률', _todoRate, const Color(0xFF0069D3)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScoreItem(String label, int value, Color dotColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF1E1E1E),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        Text(
          '$value%',
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Color(0xFF1E1E1E),
          ),
        ),
      ],
    );
  }

  // 키워드별 요약
  Widget _buildKeywordSummary(int focusRate) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFD1D1D1), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('키워드별 요약', style: kCardTitleStyle),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildKeywordCard(
                  label: '집중 시간',
                  number: '$_h',
                  unit: 'h ${_m}m',
                  backgroundColor: const Color(0xFFE0EDFF),
                  valueColor: const Color(0xFF0069FF),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildKeywordCard(
                  label: '집중률',
                  number: '$focusRate',
                  unit: '%',
                  backgroundColor: const Color(0xFFE0EDFF),
                  valueColor: const Color(0xFF0069FF),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildKeywordCard(
                  label: '졸음 감지',
                  number: '${_dailyData?.drowsyCount ?? 0}',
                  unit: '회',
                  backgroundColor: const Color(0xFFFFF5E3),
                  valueColor: const Color(0xFFBF5A00),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildKeywordCard(
                  label: '스마트폰 사용',
                  number: '${_dailyData?.phoneCount ?? 0}',
                  unit: '회',
                  backgroundColor: const Color(0xFFFFEBEC),
                  valueColor: const Color(0xFFB71D28),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKeywordCard({
    required String label,
    required String number,
    required String unit,
    required Color backgroundColor,
    required Color valueColor,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDBDBDB), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: valueColor,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: number,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: valueColor,
                      height: 1.0,
                    ),
                  ),
                  TextSpan(
                    text: unit,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
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

  // todo 달성률
  Widget _buildTodoCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFD1D1D1), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Todo 달성률',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E1E1E),
                ),
              ),
              Text(
                '$_todoDone / $_todoTotal · $_todoRate%',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0069FF),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 14,
            child: CustomPaint(
              painter: GradientProgressPainter(
                progress: _todoRate / 100,
                strokeHeight: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeSlotCard() {
    const slots = ['새벽', '오전', '점심', '오후', '저녁'];
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFD1D1D1), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('시간대별 집중도', style: kCardTitleStyle),
          const SizedBox(height: 12),
          ...slots.map((slot) {
            final rate = _timeSlotRates[slot] ?? 0;
            final isLow = rate <= 50; // 일단 50%를 기준으로 잡음
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Text(slot,
                      style: const TextStyle(fontSize: 14, color: Color(0xFF8E8E8E)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 12,
                      child: CustomPaint(
                        painter: GradientProgressPainter(
                          progress: rate / 100,
                          strokeHeight: 12,
                          isLow: isLow,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 36,
                    child: Text('$rate%',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isLow ? const Color(0xFFD43A3A) : const Color(0xFF1E1E1E),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildDisturbanceCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFD1D1D1), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('방해 요소 감지', style: kCardTitleStyle),
          const SizedBox(height: 12),
          _buildDisturbanceItem(
            iconPath: 'assets/images/drowsy_icon.png',
            iconBg: const Color(0xFFFFF5E3),
            title: '졸음 감지',
            subtitle: '${_latestDrowsyTime ?? '-'} · 약 $_latestDrowsyDuration분',
            count: _dailyData?.drowsyCount ?? 0,
            countBg: const Color(0xFFFFF5E3),
            countColor: const Color(0xFFBF5900),
          ),
          const Divider(height: 24, color: Color(0xFFEEEEEE)),
          _buildDisturbanceItem(
            iconPath: 'assets/images/smartphone_icon.png',
            iconBg: const Color(0xFFFFEBEC),
            title: '스마트폰 사용',
            subtitle: '${_latestPhoneTime ?? '-'} · 약 $_latestPhoneDuration분',
            count: _dailyData?.phoneCount ?? 0,
            countBg: const Color(0xFFFFEBEC),
            countColor: const Color(0xFFB71D28),
          ),
        ],
      ),
    );
  }

Widget _buildDisturbanceItem({
    required String iconPath,
    required Color iconBg,
    required String title,
    required String subtitle,
    required int count,
    required Color countBg,
    required Color countColor,
  }) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: iconBg,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Image.asset(iconPath, width: 24, height: 24),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF1E1E1E))),
              const SizedBox(height: 4),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color.fromARGB(255, 247, 247, 247),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '최근 감지',
                      style: TextStyle(fontSize: 12, color: Color(0xFF747474), fontWeight: FontWeight.w400),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(subtitle, style: const TextStyle(fontSize: 14, color: Color(0xFF747474))),
                ],
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: countBg,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('${count}회', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: countColor)),
        ),
      ],
    );
  }
  
  // 오늘의 공부일지 > 일지 카드 (전날 하루치)
  Widget _buildDailyJournalCard() {
    final completedTodos = _journalTodos.where((t) => t.isDone).toList();
    final incompleteTodos = _journalTodos.where((t) => !t.isDone).toList();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE0E0E0)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 날짜
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFE4EFFF),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${_getFormattedDate(daysOffset: -1)}에 생성된 공부일지',
              style: const TextStyle(fontSize: 12, color: Color(0xFF6286B8), fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(height: 10),
          if (_journalTitle != null && _journalTitle!.isNotEmpty) ...[
            Text(
              _journalTitle!,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1E1E1E), height: 1.3),
            ),
            const SizedBox(height: 10),
            Text(
              '"$_journalSubtitle"',
              style: const TextStyle(fontSize: 13, color: Color(0xFF8E8E8E), fontWeight: FontWeight.w500),
            ),
          ] else ...[
            const Text(
              // 수정 필요
              '오늘의 공부일지가 아직 생성되지 않았어요.',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1E1E1E), height: 1.3),
            ),
            const SizedBox(height: 6),
            const Text(
              // 수정 필요
              '자정에 자동으로 생성됩니다.',
              style: TextStyle(fontSize: 13, color: Color(0xFF8E8E8E), fontWeight: FontWeight.w500),
            ),
          ],
          const SizedBox(height: 15),
          // 키워드
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _buildJournalChip('집중 ${_journalH}h ${_journalM}m', const Color(0xFFDBEAFF), const Color(0xFF2881FF)),
              _buildJournalChip('달성 $_journalTodoDone/$_journalTodoTotal', const Color(0xFFE4F3ED), const Color(0xFF07733B)),
              _buildJournalChip('졸음 ${_journalData?.drowsyCount ?? 0}회', const Color(0xFFFFF5E3), const Color(0xFFBF5A00)),
              _buildJournalChip('스마트폰 ${_journalData?.phoneCount ?? 0}회', const Color(0xFFFFEBEC), const Color(0xFFB71D28)),
            ],
          ),
          const SizedBox(height: 15),
          const Divider(color: Color(0xFFDFDFDF), height: 1),
          const SizedBox(height: 12),
          // 완료한 할일
          const Text('완료한 할일', style: TextStyle(fontSize: 13, color: Color(0xFF8E8E8E), fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          if (completedTodos.isNotEmpty)
            ...completedTodos.map((t) => _buildJournalTodoItem(t.content, done: true))
          else
            const Text('완료된 할일이 없어요.', style: TextStyle(fontSize: 14, color: Color(0xFFB0B0B0))),
          const SizedBox(height: 16),
          // 미완료 · 내일로
          const Text('미완료 · 내일로', style: TextStyle(fontSize: 13, color: Color(0xFF8E8E8E), fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          if (incompleteTodos.isNotEmpty)
            ...incompleteTodos.map((t) => _buildJournalTodoItem(t.content, done: false))
          else
            const Text('미완료 항목이 없어요.', style: TextStyle(fontSize: 14, color: Color(0xFFB0B0B0))),
          const SizedBox(height: 4),
          const Divider(color: Color(0xFFEEEEEE), height: 1),
          const SizedBox(height: 12),
          // AI 한 줄 메모 + 캐릭터 (박스 위에 앉힘)
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFEBF4FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  (_advice != null && _advice!.isNotEmpty)
                      ? _advice!
                      : '아직 생성되지 않았어요.',
                  textAlign: TextAlign.justify,
                  style: const TextStyle(fontSize: 14, color: Color(0xFF1E1E1E), height: 1.6),
                ),
              ),
              Positioned(
                right: 0,
                top: -82,
                child: Image.asset('assets/images/daily_character2.png', width: 100, height: 100),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildJournalChip(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w500)),
    );
  }

  Widget _buildJournalTodoItem(String content, {required bool done}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          done
              ? const Icon(Icons.check_circle, color: Color(0xFF0069FF), size: 20)
              : const Icon(Icons.radio_button_unchecked, color: Color(0xFFD1D1D1), size: 20),
          const SizedBox(width: 10),
          Text(
            content,
            style: TextStyle(
              fontSize: 16,
              color: done ? const Color(0xFF1E1E1E) : const Color(0xFF8E8E8E),
              fontWeight: done ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  // 오늘의 공부일지 > 상단 안내 배너
  Widget _buildInfoBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FD),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFF7BB3FF)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.info_outline, color: Color(0xFF2881FF), size: 24),
          const SizedBox(width: 10),
          const Expanded(
            child: Text.rich(
              TextSpan(
                text: '공부일지는 ',
                style: TextStyle(fontSize: 14, color: Color(0xFF1E1E1E)),
                children: [
                  TextSpan(
                    text: '자정에 자동 생성',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(text: '돼요. 하루 집중 데이터, 완료/미완료 할일, AI가 생성한 조언이 함께 기록됩니다.'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

}

// 오늘의 종합 점수의 원형 차트 
class RoundedArcPainter extends CustomPainter {
  final double progress;
  final Color activeColor;
  final Color backgroundColor;
  final double strokeWidth;

  RoundedArcPainter({
    required this.progress,
    required this.activeColor,
    required this.backgroundColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    final bgPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, bgPaint);

    final rect = Rect.fromCircle(center: center, radius: radius);
    const startAngle = -math.pi / 2;
    final sweepAngle = 2 * math.pi * progress;

    canvas.drawArc(rect, startAngle, sweepAngle, false, activePaint);
  }

  @override
  bool shouldRepaint(RoundedArcPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class GradientProgressPainter extends CustomPainter {
  final double progress;
  final double strokeHeight;
  final bool isLow; 

  GradientProgressPainter({
    required this.progress,
    required this.strokeHeight,
    this.isLow = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()
      ..color = const Color(0xFFF5F5F7)
      ..style = PaintingStyle.fill;

    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, strokeHeight),
      Radius.circular(strokeHeight / 2),
    );
    canvas.drawRRect(bgRect, bgPaint);

    if (progress > 0) {
      final gradientPaint = Paint()
        ..shader = LinearGradient(
          colors: isLow
              ? const [Color(0xFFB71D28), Color(0xFFFFE1E3)]  // 빨간 그라디언트
              : const [Color(0xFF4290FF), Color(0xFFDDE7F8)], // 파란 그라디언트
        ).createShader(Rect.fromLTWH(0, 0, size.width * progress, strokeHeight))
        ..style = PaintingStyle.fill;

      final progressRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width * progress, strokeHeight),
        Radius.circular(strokeHeight / 2),
      );
      canvas.drawRRect(progressRect, gradientPaint);
    }
  }

  @override
  bool shouldRepaint(GradientProgressPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
