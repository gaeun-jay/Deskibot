// lib/screens/focus/focus_screen.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/timer_state.dart';
import '../../services/auth_service.dart';
import '../../services/timer_service.dart';
import '../../services/timer_provider.dart';

class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  TimerProvider? _timerProvider;
  int _selectedDuration = 25;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initTimerProvider();
  }

  Future<void> _initTimerProvider() async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null || !mounted) return;
    setState(() {
      _timerProvider = TimerProvider(service: TimerService(uid: uid));
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _timerProvider?.dispose();
    super.dispose();
  }

  Future<void> _showForceEndDialog(TimerProvider provider) async {
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

    return ChangeNotifierProvider<TimerProvider>.value(
      value: _timerProvider!,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('집중 모드'),
          bottom: TabBar(
            controller: _tabController,
            tabs: const [Tab(text: '뽀모도로'), Tab(text: '스톱워치')],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _PomodoroTab(
              selectedDuration: _selectedDuration,
              onDurationChanged: (v) => setState(() => _selectedDuration = v),
              onForceEnd: _showForceEndDialog,
            ),
            _StopwatchTab(onSnackbar: _showSnackbar),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
// 뽀모도로 탭
// ════════════════════════════════════════════════════════════
class _PomodoroTab extends StatelessWidget {
  final int selectedDuration;
  final ValueChanged<int> onDurationChanged;
  final Future<void> Function(TimerProvider) onForceEnd;

  const _PomodoroTab({
    required this.selectedDuration,
    required this.onDurationChanged,
    required this.onForceEnd,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimerProvider>();
    final p = provider.pomodoro;
    final isIdle =
        p.status == TimerStatus.idle || p.status == TimerStatus.finished;
    final isRunning = p.status == TimerStatus.running;
    final isAlarming = provider.isAlarming;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        children: [
          if (isAlarming)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.shade300),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.red.shade600, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    p.drowsyEvents.isNotEmpty && (p.phoneStartedAt != null || p.drowsyStartedAt != null)
                        ? '졸음 또는 폰 사용이 감지되었습니다!'
                        : p.drowsyStartedAt != null
                            ? '졸음이 감지되었습니다!'
                            : '폰 사용이 감지되었습니다!',
                    style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ],
              ),
            ),

          if (isIdle) ...[
            const Text('집중 시간 선택',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [25, 50].map((min) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: ChoiceChip(
                    label: Text('$min분'),
                    selected: selectedDuration == min,
                    onSelected: (_) => onDurationChanged(min),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 32),
          ],

          _CircularTimer(
            displayText: isIdle
                ? provider.formatSec(selectedDuration * 60)
                : provider.formatSec(p.remainingSec),
            progress: isIdle ? 1.0 : p.remainingSec / (p.durationMin * 60),
            sublabel: p.status == TimerStatus.finished
                ? '완료!'
                : isRunning
                    ? '집중 중'
                    : '시작 전',
            color: Colors.blue,
          ),

          if (!isIdle) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Badge(
                    label: '졸음 ${p.drowsyEvents.length}회',
                    color: Colors.orange),
                const SizedBox(width: 12),
                _Badge(
                    label: '폰 ${p.phoneEvents.length}회', color: Colors.red),
              ],
            ),
          ],

          const SizedBox(height: 40),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isIdle)
                _TimerBtn(
                  icon: Icons.play_arrow,
                  label: '시작',
                  onTap: () => context
                      .read<TimerProvider>()
                      .startPomodoro(selectedDuration),
                )
              else if (isRunning)
                const SizedBox.shrink(),

              if (!isIdle && p.status != TimerStatus.finished) ...[
                const SizedBox(width: 24),
                _TimerBtn(
                  icon: Icons.stop,
                  label: '종료',
                  color: Colors.red,
                  onTap: () => onForceEnd(context.read<TimerProvider>()),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
// 스톱워치 탭
// ════════════════════════════════════════════════════════════
class _StopwatchTab extends StatelessWidget {
  final void Function(String) onSnackbar;

  const _StopwatchTab({required this.onSnackbar});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TimerProvider>();
    final sw = provider.stopwatch;
    final isIdle = sw.status == TimerStatus.idle;
    final isRunning = sw.status == TimerStatus.running;
    final isPaused = sw.status == TimerStatus.paused;
    final isEsp32Started = !provider.isStopwatchStartedByApp && !isIdle;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        children: [
          _CircularTimer(
            displayText: provider.formatSec(sw.elapsedSec),
            progress: null,
            sublabel: isRunning ? '집중 중' : isPaused ? '일시정지' : '시작 전',
            color: Colors.green,
          ),

          if (isEsp32Started) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.smart_toy, size: 14, color: Colors.grey.shade500),
                const SizedBox(width: 4),
                Text('로봇에서 시작됨',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              ],
            ),
          ],

          if (sw.pauseEvents.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '일시정지 ${sw.pauseEvents.length}회 · 총 ${sw.totalPauseDuration}분',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ],

          const SizedBox(height: 40),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isIdle)
                _TimerBtn(
                  icon: Icons.play_arrow,
                  label: '시작',
                  onTap: () async {
                    final success =
                        await context.read<TimerProvider>().startStopwatch();
                    if (!success) onSnackbar('이미 실행 중인 세션이 있습니다.');
                  },
                ),

              if (isRunning)
                _TimerBtn(
                  icon: Icons.pause,
                  label: '일시정지',
                  onTap: () => context.read<TimerProvider>().pauseStopwatch(),
                ),

              if (isPaused) ...[
                _TimerBtn(
                  icon: Icons.play_arrow,
                  label: '재시작',
                  onTap: () => context.read<TimerProvider>().resumeStopwatch(),
                ),
                const SizedBox(width: 16),
                _TimerBtn(
                  icon: Icons.stop,
                  label: '종료',
                  color: Colors.red,
                  onTap: () => context.read<TimerProvider>().endStopwatch(),
                ),
                const SizedBox(width: 16),
                _TimerBtn(
                  icon: Icons.refresh,
                  label: '초기화',
                  color: Colors.grey,
                  onTap: () => context.read<TimerProvider>().resetStopwatch(),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
// 공통 위젯
// ════════════════════════════════════════════════════════════
class _CircularTimer extends StatelessWidget {
  final String displayText;
  final double? progress;
  final String sublabel;
  final Color color;

  const _CircularTimer({
    required this.displayText,
    required this.progress,
    required this.sublabel,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (progress != null)
            CircularProgressIndicator(
              value: progress,
              strokeWidth: 10,
              backgroundColor: Colors.grey.shade200,
              color: color,
              strokeCap: StrokeCap.round,
            ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(displayText,
                  style: const TextStyle(
                      fontSize: 48, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(sublabel,
                  style:
                      TextStyle(color: Colors.grey.shade600, fontSize: 14)),
            ],
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
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 13)),
    );
  }
}

class _TimerBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  const _TimerBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.blue,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            foregroundColor: Colors.white,
            shape: const CircleBorder(),
            padding: const EdgeInsets.all(20),
          ),
          child: Icon(icon, size: 32),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
