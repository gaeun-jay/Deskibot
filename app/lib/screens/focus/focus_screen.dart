import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:deskibot/services/api_client.dart';

import '../../models/timer_state.dart';
import '../../services/auth_service.dart';
import '../../services/timer_service.dart';
import '../../services/timer_provider.dart';
import '../../theme/app_styles.dart';

const _kMain = Color(0xFF2881FF);

class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  TimerProvider? _timerProvider;
  String? _uid;
  int _selectedDuration = 25;
  List<Map<String, dynamic>> _todaySessions = [];
  String? _loadedDate;
  Timer? _dateCheckTimer;

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );
    _init();

    // 이 화면도 IndexedStack 으로 계속 떠 있을 수 있어서, 아무 조작 없이
    // 자정을 넘기면 "오늘 세션" 목록이 어제 걸로 멈춰있을 수 있다.
    // 1분마다 스스로 날짜가 바뀌었는지 확인한다.
    _dateCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_uid != null && _loadedDate != null && _loadedDate != _todayStr()) {
        _loadTodaySessions(_uid!);
      }
    });
  }

  Future<void> _init() async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null || !mounted) return;
    setState(() {
      _uid = uid;
      _timerProvider = TimerProvider(service: TimerService(uid: uid));
    });
    await _loadTodaySessions(uid);
  }

  Future<void> _loadTodaySessions(String uid) async {
    final dateStr = _todayStr();
    // 카드가 개수만 쓰므로 서버 응답 맵을 그대로 담는다.
    final res = await ApiClient()
        .get('/api/focus-sessions', query: {'date': dateStr});
    final completed = (res['sessions'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((s) =>
            s['status'] == 'completed' || s['status'] == 'incomplete')
        .toList();
    if (!mounted) return;
    setState(() {
      _todaySessions = completed;
      _loadedDate = dateStr;
    });
  }

  @override
  void dispose() {
    _dateCheckTimer?.cancel();
    _tabController.dispose();
    _timerProvider?.dispose();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
    );
    super.dispose();
  }

  Future<void> _showEndDialog(TimerProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('학습을 종료하시겠습니까?'),
        content: const Text('지금까지의 집중 기록은 저장됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('계속하기'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('종료'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await provider.forceEndPomodoro();
      if (_uid != null) await _loadTodaySessions(_uid!);
    }
  }

  void _showSnackbar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_timerProvider == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final statusBarH = MediaQuery.of(context).padding.top;
    // 그라디언트 헤더 높이 (상태바 + 텍스트 영역)
    final headerH = statusBarH + 186.0;

    return ChangeNotifierProvider<TimerProvider>.value(
      value: _timerProvider!,
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F6FA),
        body: Stack(
          children: [
            // ── 1) 그라디언트 배경 ────────────────────────────
            Positioned.fill(
              child: Container(
                decoration: const BoxDecoration(gradient: kAppBackgroundGradient),
              ),
            ),

            // ── 2) 헤더 텍스트 ───────────────────────────────
            Positioned(
              top: statusBarH + 56,
              left: 20,
              right: 160,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('집중 모드', style: kHeaderTitleStyle),
                  SizedBox(height: 4),
                  Text(
                    '뽀모도로와 스톱워치를 사용하여 집중 세션을 시작하세요.',
                    style: kHeaderSubtitleStyle,
                  ),
                ],
              ),
            ),

            // ── 3) 캐릭터 (흰 카드 뒤에 렌더링) ─────────────
            Positioned(
              top: statusBarH + 16,
              right: -10,
              child: Image.asset(
                'assets/images/character_focus.png',
                width: 180,
                height: 180,
                fit: BoxFit.contain,
              ),
            ),

            // ── 4) 흰 카드 (탭바 + 콘텐츠) ───────────────────
            Positioned(
              top: headerH,
              left: 14,
              right: 14,
              bottom: 0,
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
                    // 탭바 (흰 카드 안)
                    TabBar(
                      controller: _tabController,
                      tabs: const [
                        Tab(text: '뽀모도로'),
                        Tab(text: '스톱워치'),
                      ],
                      labelColor: _kMain,
                      unselectedLabelColor: const Color(0xFFA2A2A2),
                      indicatorColor: _kMain,
                      indicatorWeight: 2,
                      labelStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    // 탭 콘텐츠
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _PomodoroTabView(
                            selectedDuration: _selectedDuration,
                            onDurationChanged: (v) =>
                                setState(() => _selectedDuration = v),
                            onEnd: _showEndDialog,
                            todaySessions: _todaySessions,
                          ),
                          _StopwatchTab(
                            onSnackbar: _showSnackbar,
                            todaySessions: _todaySessions,
                            onSessionEnd: () async {
                              if (_uid != null) await _loadTodaySessions(_uid!);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
// 뽀모도로 탭
// ════════════════════════════════════════════════════════════
class _PomodoroTabView extends StatelessWidget {
  final int selectedDuration;
  final ValueChanged<int> onDurationChanged;
  final Future<void> Function(TimerProvider) onEnd;
  final List<Map<String, dynamic>> todaySessions;

  const _PomodoroTabView({
    required this.selectedDuration,
    required this.onDurationChanged,
    required this.onEnd,
    required this.todaySessions,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimerProvider>();
    final p = provider.pomodoro;
    final isIdle =
        p.status == TimerStatus.idle || p.status == TimerStatus.finished;
    final isRunning = p.status == TimerStatus.running;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        children: [
          // ── 타이머 카드 ──────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFD1D1D1)),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Column(
              children: [
                if (provider.isAlarming) ...[
                  _AlarmBanner(p: p),
                  const SizedBox(height: 12),
                ],

                // 25분 / 50분 토글
                if (isIdle) ...[
                  _DurationToggle(
                    selected: selectedDuration,
                    onChanged: onDurationChanged,
                  ),
                  const SizedBox(height: 24),
                ],

                // 타이머 원
                _CircularTimer(
                  displayText: isIdle
                      ? provider.formatSec(selectedDuration * 60)
                      : provider.formatSec(p.remainingSec),
                  progress: isIdle
                      ? 1.0
                      : p.remainingSec / (p.durationMin * 60),
                  sublabel: p.status == TimerStatus.finished
                      ? '완료!'
                      : isRunning
                      ? '집중 중'
                      : '준비',
                  imagePath: 'assets/images/tomato_img.png',
                ),

                if (!isIdle) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _Badge(
                        label: '졸음 ${p.drowsyEvents.length}회',
                        color: Colors.orange,
                      ),
                      const SizedBox(width: 12),
                      _Badge(
                        label: '폰 ${p.phoneEvents.length}회',
                        color: Colors.red,
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 32),

                // 버튼: 시작 → 종료
                _PillBtn(
                  label: isIdle ? '시작' : '종료',
                  filled: true,
                  color: isIdle ? _kMain : Colors.red,
                  onTap: isIdle
                      ? () => context.read<TimerProvider>().startPomodoro(
                          selectedDuration,
                        )
                      : () => onEnd(context.read<TimerProvider>()),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── 오늘 집중 세션 카드 ──────────────────────────────
          _TodaySessionsCard(sessions: todaySessions),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
// 스톱워치 탭
// ════════════════════════════════════════════════════════════
class _StopwatchTab extends StatefulWidget {
  final void Function(String) onSnackbar;
  final List<Map<String, dynamic>> todaySessions;
  final VoidCallback onSessionEnd;

  const _StopwatchTab({
    required this.onSnackbar,
    required this.todaySessions,
    required this.onSessionEnd,
  });

  @override
  State<_StopwatchTab> createState() => _StopwatchTabState();
}

class _StopwatchTabState extends State<_StopwatchTab> {
  Timer? _displayTicker;

  @override
  void initState() {
    super.initState();
    _displayTicker = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _displayTicker?.cancel();
    super.dispose();
  }

  int _elapsedMs(StopwatchState sw) {
    if (sw.startedAt == null) return 0;
    final base = (sw.status == TimerStatus.paused && sw.pausedAt != null)
        ? sw.pausedAt!
        : DateTime.now();
    return (base.difference(sw.startedAt!).inMilliseconds - sw.totalPauseMs)
        .clamp(0, double.maxFinite)
        .toInt();
  }

  String _fmtMs(int ms) {
    final m = (ms ~/ 60000).toString().padLeft(2, '0');
    final s = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
    final cs = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
    return '$m:$s.$cs';
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimerProvider>();
    final sw = provider.stopwatch;
    final isIdle = sw.status == TimerStatus.idle;
    final isRunning = sw.status == TimerStatus.running;
    final isPaused = sw.status == TimerStatus.paused;

    final elapsedMs = _elapsedMs(sw);
    final displayText = isIdle ? '0:00:00' : _fmtMs(elapsedMs);
    final arcProgress = isIdle ? 0.0 : (elapsedMs % 60000) / 60000;
    final sublabel = isRunning
        ? '스톱워치 진행 중'
        : isPaused
        ? '스톱워치 일시정지'
        : '스톱워치 준비';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        children: [
          // ── 타이머 카드 ─────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFD1D1D1)),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Column(
              children: [
                _CircularTimer(
                  displayText: displayText,
                  progress: arcProgress,
                  sublabel: sublabel,
                  fontSize: isIdle ? 40 : 36,
                ),
                const SizedBox(height: 20),

                // ── 버튼 ────────────────────────────────────
                if (isIdle)
                  _PillBtn(
                    label: '시작',
                    filled: true,
                    onTap: () async {
                      final ok = await context
                          .read<TimerProvider>()
                          .startStopwatch();
                      if (!ok) widget.onSnackbar('이미 실행 중인 세션이 있습니다.');
                    },
                  )
                else if (isRunning)
                  _PillBtn(
                    label: '일시정지',
                    filled: true,
                    color: const Color(0xFFEEEEEE),
                    textColor: const Color(0xFF555555),
                    onTap: () => context.read<TimerProvider>().pauseStopwatch(),
                  )
                else if (isPaused)
                  Row(
                    children: [
                      Expanded(
                        child: _PillBtn(
                          label: '종료',
                          filled: true,
                          color: const Color(0xFFEEEEEE),
                          textColor: const Color(0xFF555555),
                          onTap: () async {
                            await context.read<TimerProvider>().endStopwatch();
                            widget.onSessionEnd();
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _PillBtn(
                          label: '계속',
                          filled: true,
                          onTap: () =>
                              context.read<TimerProvider>().resumeStopwatch(),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── 오늘 집중 세션 ──────────────────────────────────
          _TodaySessionsCard(sessions: widget.todaySessions),
        ],
      ),
    );
  }
}

// ── 구간 기록 테이블 ──────────────────────────────────────────
// ════════════════════════════════════════════════════════════
// 오늘 집중 세션 카드
// ════════════════════════════════════════════════════════════
class _TodaySessionsCard extends StatelessWidget {
  final List<Map<String, dynamic>> sessions;
  const _TodaySessionsCard({required this.sessions});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFD1D1D1)),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더
          Container(
            width: double.infinity,
            height: 59,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              color: Color(0xFFE9F2FF),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(15),
                topRight: Radius.circular(15),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 29,
                  height: 29,
                  decoration: const BoxDecoration(
                    color: Color(0xFFECF3FC),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.access_time, size: 16, color: _kMain),
                ),
                const SizedBox(width: 10),
                const Text(
                  '오늘 집중 세션',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6286B8),
                  ),
                ),
              ],
            ),
          ),
          if (sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '오늘 완료된 세션이 없어요.',
                  style: TextStyle(fontSize: 13, color: Color(0xFFAAAAAA)),
                ),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 305),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                physics: sessions.length > 5
                    ? const AlwaysScrollableScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                itemCount: sessions.length,
                itemBuilder: (_, i) => _SessionItem(
                  session: sessions[i],
                  showDivider: i < sessions.length - 1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SessionItem extends StatelessWidget {
  final Map<String, dynamic> session;
  final bool showDivider;
  const _SessionItem({required this.session, required this.showDivider});

  /// 초를 "n분 m초" 또는 "n초" 형식으로 변환
  String _fmtDuration(int sec) {
    if (sec <= 0) return '';
    final m = sec ~/ 60;
    final s = sec % 60;
    if (m == 0) return '$s초';
    if (s == 0) return '$m분';
    return '$m분 $s초';
  }

  @override
  Widget build(BuildContext context) {
    final type = session['type'] as String? ?? '';
    final plannedMin =
        ((session['planned_duration_sec'] as num?)?.toInt() ?? 0) ~/ 60;
    final actualSec =
        (session['actual_duration_sec'] as num?)?.toInt() ?? 0;
    final startTime = session['start_time'] as String? ?? '';
    final endTime = session['end_time'] as String? ?? '';

    final String label;
    if (type == 'pomodoro') {
      label = plannedMin > 0 ? '$plannedMin분 완료' : '뽀모도로 완료';
    } else {
      label = actualSec > 0 ? '스톱워치 ${_fmtDuration(actualSec)}' : '스톱워치 완료';
    }

    return Container(
      height: 61,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: showDivider
          ? const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFDFDFDF))),
            )
          : null,
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: Color(0xFFECF3FC),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.access_time, size: 18, color: _kMain),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1E1E1E),
                  ),
                ),
                if (startTime.isNotEmpty && endTime.isNotEmpty)
                  Text(
                    '$startTime ~ $endTime',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF8E8E8E),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFFE4F3ED),
              borderRadius: BorderRadius.circular(30),
            ),
            child: const Text(
              '완료',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF07733B),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
// 공통 위젯
// ════════════════════════════════════════════════════════════
class _DurationToggle extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onChanged;
  const _DurationToggle({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [25, 50].map((min) {
        final isSelected = selected == min;
        return GestureDetector(
          onTap: () => onChanged(min),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 79,
            height: 39,
            margin: EdgeInsets.only(right: min == 25 ? 8 : 0),
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFF1E1E1E)
                  : const Color(0xFFF6F6F6),
              borderRadius: BorderRadius.circular(50),
              border: isSelected
                  ? null
                  : Border.all(color: const Color(0xFFDFDFDF)),
            ),
            alignment: Alignment.center,
            child: Text(
              '$min분',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isSelected ? Colors.white : const Color(0xFFA2A2A2),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _CircularTimer extends StatelessWidget {
  final String displayText;
  final double progress;
  final String sublabel;
  final String? imagePath;
  final double fontSize;

  const _CircularTimer({
    required this.displayText,
    required this.progress,
    required this.sublabel,
    this.imagePath,
    this.fontSize = 40,
  });

  @override
  Widget build(BuildContext context) {
    const size = 222.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (progress >= 1.0)
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: _kMain, width: 7),
              ),
            )
          else
            CustomPaint(
              size: const Size(size, size),
              painter: _ArcPainter(progress: progress),
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (imagePath != null) ...[
                Image.asset(imagePath!, width: 105, height: 105),
                const SizedBox(height: 4),
              ],
              Text(
                displayText,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF1E1E1E),
                ),
              ),
              Text(
                sublabel,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFFA2A2A2),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  final double progress;
  const _ArcPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = const Color(0xFFEEEEEE)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      Paint()
        ..color = _kMain
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.progress != progress;
}

class _PillBtn extends StatelessWidget {
  final String label;
  final bool filled;
  final Color color;
  final Color? textColor;
  final VoidCallback onTap;

  const _PillBtn({
    required this.label,
    required this.filled,
    required this.onTap,
    this.color = _kMain,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final fgColor = textColor ?? (filled ? Colors.white : _kMain);
    return SizedBox(
      width: 268,
      height: 56,
      child: filled
          ? ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                foregroundColor: fgColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(50),
                ),
                elevation: 0,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: fgColor,
                ),
              ),
            )
          : OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                foregroundColor: fgColor,
                side: BorderSide(color: color, width: 2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(50),
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: fgColor,
                ),
              ),
            ),
    );
  }
}

class _AlarmBanner extends StatelessWidget {
  final PomodoroState p;
  const _AlarmBanner({required this.p});

  @override
  Widget build(BuildContext context) {
    final msg = p.drowsyStartedAt != null ? '졸음이 감지되었습니다!' : '폰 사용이 감지되었습니다!';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.shade300),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: Colors.red.shade600,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            msg,
            style: TextStyle(
              color: Colors.red.shade700,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 13)),
    );
  }
}
