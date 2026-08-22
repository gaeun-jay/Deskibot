import 'dart:async';
import 'dart:math' show sqrt;
import 'package:flutter/material.dart';
import 'package:glassmorphism/glassmorphism.dart';
import 'package:deskibot/models/cumulative_stats_model.dart';
import 'package:deskibot/services/cumulative_stats_service.dart';
import 'package:deskibot/theme/app_styles.dart';

class CumulativeAnalysisScreen extends StatefulWidget {
  const CumulativeAnalysisScreen({super.key});

  @override
  State<CumulativeAnalysisScreen> createState() =>
      _CumulativeAnalysisScreenState();
}

class _CumulativeAnalysisScreenState extends State<CumulativeAnalysisScreen> {
  int _selectedPeriod = 0;
  bool _loading = false;
  CumulativeStatsModel? _stats;
  CumulativeAnalysisModel? _analysis;
  final List<String> _periods = ['1주', '1달', '3달', '6달', '1년'];

  String? _loadedDate;
  Timer? _dateCheckTimer;

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    _loadStats();

    // 이 화면도 IndexedStack 으로 계속 떠 있을 수 있어서, 탭 전환 없이
    // 자정을 넘기면 날짜가 안 바뀔 수 있다. 1분마다 스스로 확인한다.
    _dateCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_loadedDate != null && _loadedDate != _todayStr()) {
        _loadStats();
      }
    });
  }

  @override
  void dispose() {
    _dateCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadStats() async {
    setState(() => _loading = true);
    try {
      final service = CumulativeStatsService();
      final results = await Future.wait([
        service.fetchStats(_selectedPeriod),
        service.fetchAnalysis(_selectedPeriod),
      ]);
      if (mounted) {
        setState(() {
          _stats    = results[0] as CumulativeStatsModel?;
          _analysis = results[1] as CumulativeAnalysisModel?;
          _loadedDate = _todayStr();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // period-aware x-axis labels
  List<String> get _chartLabels {
    switch (_selectedPeriod) {
      case 0:
        return ['월', '화', '수', '목', '금', '토', '일'];
      case 1:
        return ['1주', '2주', '3주', '4주'];
      case 2:
        return ['1월', '2월', '3월'];
      case 3:
        return ['1월', '2월', '3월', '4월', '5월', '6월'];
      case 4:
        return ['1분기', '2분기', '3분기', '4분기'];
      default:
        return [];
    }
  }

  String get _chartPeriodTitle {
    switch (_selectedPeriod) {
      case 0:
        return '요일별';
      case 1:
        return '주차별';
      case 2:
      case 3:
        return '달별';
      case 4:
        return '분기별';
      default:
        return '';
    }
  }

  String _getPeriodDateRange() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));
    return '${monday.month}/${monday.day} ~ ${sunday.month}/${sunday.day}';
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
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF0069FF)))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
                      child: Column(
                        children: [
                          _buildPeriodInfo(),
                          const SizedBox(height: 10),
                          _buildAISummary(),
                          const SizedBox(height: 12),
                          _buildSummaryCards(),
                          const SizedBox(height: 12),
                          _buildFocusBarChart(),
                          const SizedBox(height: 12),
                          _buildDistractionLineChart(),
                          const SizedBox(height: 12),
                          _buildTimeHeatmap(),
                          const SizedBox(height: 12),
                          _buildInsights(),
                          const SizedBox(height: 12),
                          _buildAIRoutine(),
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
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/images/cumulative_character.png',
                  width: kHeaderCharacterSize,
                  height: kHeaderCharacterSize,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.bar_chart,
                    size: kHeaderCharacterSize,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 14),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('누적 분석', style: kHeaderTitleStyle),
                    SizedBox(height: 6),
                    Text(
                      '나는 어떤 패턴을 가진 사람인지\n확인해보세요.',
                      style: kHeaderSubtitleStyle,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildPeriodSelector(),
          ],
        ),
      ),
    );
  }

  Widget _buildPeriodSelector() {
    return SizedBox(
      height: 44,
      child: Row(
        children: List.generate(_periods.length, (i) {
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == _periods.length - 1 ? 0 : 6),
              child: _buildPeriodTabItem(index: i, label: _periods[i]),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildPeriodTabItem({required int index, required String label}) {
    final isSelected = _selectedPeriod == index;
    return GestureDetector(
      onTap: () {
        setState(() => _selectedPeriod = index);
        _loadStats();
      },
      child: GlassmorphicContainer(
        width: double.infinity,
        height: double.infinity,
        borderRadius: 50,
        blur: 15,
        border: 1.5,
        linearGradient: LinearGradient(
          colors: isSelected
              ? const [
                  Color.fromRGBO(0, 115, 255, 0.3),
                  Color.fromRGBO(0, 115, 255, 0.3),
                ]
              : const [
                  Color.fromRGBO(167, 167, 167, 0.3),
                  Color.fromRGBO(167, 167, 167, 0.3),
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
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPeriodInfo() {
    final labels = [
      '이번 주 (${_getPeriodDateRange()})',
      '이번 달',
      '최근 3달',
      '최근 6달',
      '최근 1년',
    ];
    return _card(
      child: Row(
        children: [
          const Icon(Icons.calendar_month_outlined,
              color: Color(0xFF0069FF), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              labels[_selectedPeriod],
              style: const TextStyle(
                  fontSize: 13,
                  color: Colors.black87,
                  fontWeight: FontWeight.w500),
            ),
          ),
          const Icon(Icons.refresh, color: Colors.grey, size: 20),
        ],
      ),
    );
  }

  /// 아직 리포트가 없을 때 보여줄 안내.
  ///
  /// 누적 리포트는 서버 스케줄러가 직전 달력 기간이 끝난 뒤에 만든다
  /// (server/sw/app/scheduler.py 의 CUMULATIVE_SCHEDULE). 앱에서 생성을
  /// 요청하지 않으므로, 대신 언제 생기는지를 알려준다.
  String _pendingAnalysisMessage() {
    switch (_selectedPeriod) {
      case 0:
        return '지난주 리포트는 매주 월요일 아침에 만들어져요.';
      case 1:
        return '지난달 리포트는 매월 1일 아침에 만들어져요.';
      case 2:
        return '분기 리포트는 1·4·7·10월 1일 아침에 만들어져요.';
      case 3:
        return '반기 리포트는 1월과 7월 1일 아침에 만들어져요.';
      default:
        return '연간 리포트는 매년 1월 1일 아침에 만들어져요.';
    }
  }

  Widget _buildAISummary() {
    final summary = _analysis?.summary;
    final hasData = summary != null && summary.isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: hasData ? const Color(0xFFEEF4FF) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasData ? const Color(0xFFB8D4FF) : const Color(0xFFE0E0E0),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Image.asset(
            'assets/images/cumulative_icon.png',
            width: 40,
            height: 40,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasData ? summary : _pendingAnalysisMessage(),
              style: TextStyle(
                fontSize: 13,
                color: hasData ? const Color(0xFF0069FF) : Colors.black38,
                fontWeight: hasData ? FontWeight.w600 : FontWeight.w400,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCards() {
    final s = _stats;
    final (focusValue, focusUnit) =
        s == null ? ('--', '') : _fmtFocusSplit(s.totalFocusMinutes);
    final avgFocus = s == null ? '--' : s.avgFocusRate.toStringAsFixed(1);
    final avgAchieve = s == null ? '--' : s.avgAchievementRate.toStringAsFixed(1);
    final totalDist = s == null ? '--' : '${s.totalDistractions}';

    return _sectionCard(
      title: '키워드별 요약',
      titleGap: 10,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _SummaryCard(
                  label: '누적 집중',
                  value: focusValue,
                  unit: focusUnit,
                  accentColor: const Color(0xFF0069FF),
                  bgColor: const Color(0xFFDEEBFF),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SummaryCard(
                  label: '평균 집중률',
                  value: avgFocus,
                  unit: '%',
                  accentColor: const Color(0xFF0069FF),
                  bgColor: const Color(0xFFDEEBFF),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _SummaryCard(
                  label: '평균 달성률',
                  value: avgAchieve,
                  unit: '%',
                  accentColor: const Color(0xFF0069FF),
                  bgColor: const Color(0xFFDEEBFF),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SummaryCard(
                  label: '총 방해 감지',
                  value: totalDist,
                  unit: s == null ? '' : '회',
                  accentColor: const Color(0xFFB71D28),
                  bgColor: const Color(0xFFFFE0E0),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _fmtMinutes(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  (String, String) _fmtFocusSplit(int minutes) {
    if (minutes < 60) return ('$minutes', '분');
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? ('$h', 'h') : ('$h', 'h ${m}분');
  }

  Widget _buildFocusBarChart() {
    final days = _stats?.days ?? [];
    final labels = days.isNotEmpty ? days.map((d) => d.label).toList() : _chartLabels;
    final maxMinutes = days.isEmpty
        ? 1
        : days.fold(0, (m, d) => d.focusMinutes > m ? d.focusMinutes : m);
    final activeDays = days.where((d) => d.focusMinutes > 0).toList();
    final avgMinutes = activeDays.isEmpty
        ? 0
        : activeDays.fold(0, (s, d) => s + d.focusMinutes) ~/ activeDays.length;

    return _sectionCard(
      title: '$_chartPeriodTitle 집중 시간',
      trailing: const Text('단위: 분',
          style: TextStyle(fontSize: 11, color: Colors.grey)),
      child: Column(
        children: [
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(labels.length, (i) {
                final minutes = i < days.length ? days[i].focusMinutes : 0;
                final ratio = maxMinutes == 0 ? 0.0 : minutes / maxMinutes;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (minutes > 0)
                                  Text('$minutes',
                                      style: const TextStyle(fontSize: 9, color: Colors.black54)),
                                const SizedBox(height: 2),
                                Container(
                                  width: double.infinity,
                                  height: (ratio * 80).clamp(2.0, 80.0),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0069FF)
                                        .withValues(alpha: minutes > 0 ? 0.7 : 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(labels[i],
                            style: const TextStyle(fontSize: 10, color: Colors.grey)),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 212,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F8FF),
                borderRadius: BorderRadius.circular(19),
              ),
              alignment: Alignment.center,
              child: Text(
                avgMinutes == 0
                    ? '평균 데이터 없음'
                    : '${_periods[_selectedPeriod]} 평균: ${_fmtMinutes(avgMinutes)}',
                style: const TextStyle(
                  fontSize: 16,
                  color: Color(0xFF2881FF),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDistractionLineChart() {
    final days = _stats?.days ?? [];
    final labels = days.isNotEmpty ? days.map((d) => d.label).toList() : _chartLabels;
    final drowsy = days.isNotEmpty
        ? days.map((d) => d.drowsyCount.toDouble()).toList()
        : List<double>.filled(labels.length, 0);
    final phone = days.isNotEmpty
        ? days.map((d) => d.phoneCount.toDouble()).toList()
        : List<double>.filled(labels.length, 0);
    // 모든 값이 0이면 차트 그리기 방지용으로 더미 최솟값
    final hasData = drowsy.any((v) => v > 0) || phone.any((v) => v > 0);

    return _sectionCard(
      title: '$_chartPeriodTitle 방해 요소 추이',
      child: Column(
        children: [
          SizedBox(
            height: 130,
            width: double.infinity,
            child: hasData
                ? CustomPaint(
                    painter: _LineChartPainter(
                      drowsyData: drowsy,
                      phoneData: phone,
                      labels: labels,
                    ),
                  )
                : Center(
                    child: Text('방해 감지 데이터 없음',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legendDot(const Color(0xFF009AFF), '졸음'),
              const SizedBox(width: 16),
              _legendDash(const Color(0xFF0069D3), '스마트폰 사용'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTimeHeatmap() {
    final days = _stats?.days ?? [];
    final colLabels = days.isNotEmpty
        ? days.map((d) => d.label).toList()
        : _chartLabels;

    // slot key → 표시 레이블
    const slotKeys = ['dawn', 'morning', 'afternoon', 'night'];
    const slotLabels = ['새벽\n(00~06시)', '오전\n(06~12시)', '오후\n(12~18시)', '저녁\n(18~24시)'];

    // 전체 셀 중 최댓값 (색상 정규화용)
    int maxVal = 1;
    for (final day in days) {
      for (final key in slotKeys) {
        final v = day.timeSlots[key]?.total ?? 0;
        if (v > maxVal) maxVal = v;
      }
    }

    Color cellColor(int val) {
      if (val == 0) return const Color(0xFFF0F4FF);
      final ratio = (val / maxVal).clamp(0.0, 1.0);
      return Color.lerp(const Color(0xFFBDD7FF), const Color(0xFF0040CC), ratio)!;
    }

    return _sectionCard(
      title: '시간대별 히트맵',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 컬럼 헤더
          Row(
            children: [
              const SizedBox(width: 56),
              ...colLabels.map((label) => Expanded(
                    child: Center(
                      child: Text(label,
                          style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    ),
                  )),
            ],
          ),
          const SizedBox(height: 6),
          // 히트맵 행
          ...List.generate(slotKeys.length, (si) {
            final key = slotKeys[si];
            final slotLabel = slotLabels[si];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(slotLabel,
                        style: const TextStyle(fontSize: 9, color: Colors.grey),
                        textAlign: TextAlign.right),
                  ),
                  const SizedBox(width: 4),
                  ...List.generate(colLabels.length, (di) {
                    final val = di < days.length
                        ? (days[di].timeSlots[key]?.total ?? 0)
                        : 0;
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Tooltip(
                          message: val == 0 ? '감지 없음' : '감지 $val회',
                          child: Container(
                            height: 26,
                            decoration: BoxDecoration(
                              color: cellColor(val),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: val > 0
                                ? Center(
                                    child: Text('$val',
                                        style: const TextStyle(
                                            fontSize: 9,
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600)),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            );
          }),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _heatmapLegend(const Color(0xFFF0F4FF), '없음'),
              const SizedBox(width: 6),
              _heatmapLegend(const Color(0xFF6BAEFF), '보통'),
              const SizedBox(width: 6),
              _heatmapLegend(const Color(0xFF0040CC), '많음'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heatmapLegend(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 12, height: 12,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 3),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }

  Color _patternColor(String type) {
    switch (type) {
      case 'distraction': return const Color(0xFFFF9800);
      case 'todo':        return const Color(0xFF4CAF50);
      default:            return const Color(0xFF0069FF); // focus
    }
  }

  Widget _buildInsights() {
    final patterns = _analysis?.patterns;
    final hasData = patterns != null && patterns.isNotEmpty;

    return _sectionCard(
      title: '반복 패턴',
      trailing: _analysis == null ? null : _periodBadge(_analysis!.periodLabel),
      child: hasData
          ? Column(
              children: [
                for (int i = 0; i < patterns.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  _InsightItem(
                    color: _patternColor(patterns[i].type),
                    title: patterns[i].title,
                    body: patterns[i].body,
                  ),
                ],
              ],
            )
          : Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_pendingAnalysisMessage(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Colors.black38)),
              ),
            ),
    );
  }

  Widget _buildAIRoutine() {
    final routine = _analysis?.routine;
    final hasData = routine != null && routine.isNotEmpty;

    return _card(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Image.asset(
                'assets/images/routine_character.png',
                width: 64,
                height: 64,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.smart_toy, size: 64, color: Color(0xFF6286B8)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('AI 루틴 제안', style: kCardTitleStyle),
                    const SizedBox(height: 3),
                    const Text(
                      'AI가 제안한 루틴을 타임테이블에 추가해 보세요.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9E9E9E),
                      ),
                    ),
                  ],
                ),
              ),
              if (_analysis != null) _periodBadge(_analysis!.periodLabel),
            ],
          ),
          const SizedBox(height: 14),
          hasData
              ? Column(
                  children: [
                    for (int i = 0; i < routine.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      _AIRoutineItem(
                        time: routine[i].time,
                        label: routine[i].label,
                        body: routine[i].body,
                      ),
                    ],
                  ],
                )
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(_pendingAnalysisMessage(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13, color: Colors.black38)),
                  ),
                ),
        ],
      ),
    );
  }

  Widget _periodBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF4FF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$label 기준',
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Color(0xFF6286B8),
        ),
      ),
    );
  }

  Widget _card({required Widget child, EdgeInsets? padding}) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(14),
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
      child: child,
    );
  }

  Widget _sectionCard({
    required String title,
    required Widget child,
    Widget? trailing,
    double titleGap = 14,
  }) {
    return _card(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: kCardTitleStyle),
              ?trailing,
            ],
          ),
          SizedBox(height: titleGap),
          child,
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ],
    );
  }

  Widget _legendDash(Color color, String label) {
    return Row(
      children: [
        CustomPaint(
          size: const Size(20, 10),
          painter: _DashLegendPainter(color: color),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color accentColor;
  final Color bgColor;

  const _SummaryCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.accentColor,
    required this.bgColor,
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

class _InsightItem extends StatelessWidget {
  final Color color;
  final String title;
  final String body;

  const _InsightItem({
    required this.color,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.only(top: 3),
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87)),
              const SizedBox(height: 2),
              Text(body,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
          ),
        ),
      ],
    );
  }
}

class _AIRoutineItem extends StatelessWidget {
  final String time;
  final String label;
  final String body;

  const _AIRoutineItem({
    required this.time,
    required this.label,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE8EEF7)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$time · $label',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                if (body.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFDEEBFF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '+ 추가',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF0069FF),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<double> drowsyData;
  final List<double> phoneData;
  final List<String> labels;

  const _LineChartPainter({
    required this.drowsyData,
    required this.phoneData,
    required this.labels,
  });

  static const _yAxisWidth = 30.0;
  static const _xLabelHeight = 18.0;
  static const _topPad = 14.0;
  static const _drowsyColor = Color(0xFF009AFF);
  static const _phoneColor = Color(0xFF0069D3);

  int _niceMax(double raw) {
    if (raw <= 0) return 5;
    if (raw <= 5) return 5;
    if (raw <= 10) return 10;
    if (raw <= 15) return 15;
    if (raw <= 20) return 20;
    return (((raw / 5).ceil()) * 5);
  }

  double _xOf(int i, int total, double left, double width) {
    if (total <= 1) return left + width / 2;
    return left + i * width / (total - 1);
  }

  double _yOf(double val, double niceMax, double top, double height) {
    return top + height - (val / niceMax) * height;
  }

  void _drawDashed(Canvas canvas, List<Offset> pts, Paint paint) {
    const dash = 5.0;
    const gap = 4.0;
    for (int i = 0; i < pts.length - 1; i++) {
      final s = pts[i];
      final e = pts[i + 1];
      final dx = e.dx - s.dx;
      final dy = e.dy - s.dy;
      final len = sqrt(dx * dx + dy * dy);
      if (len < 0.01) continue;
      final ux = dx / len;
      final uy = dy / len;
      double d = 0;
      bool draw = true;
      while (d < len) {
        final seg = draw ? dash : gap;
        final next = (d + seg).clamp(0.0, len);
        if (draw) {
          canvas.drawLine(
            Offset(s.dx + ux * d, s.dy + uy * d),
            Offset(s.dx + ux * next, s.dy + uy * next),
            paint,
          );
        }
        d = next;
        draw = !draw;
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final allVals = [...drowsyData, ...phoneData];
    final rawMax = allVals.fold(0.0, (m, v) => v > m ? v : m);
    final niceMax = _niceMax(rawMax).toDouble();

    final left = _yAxisWidth;
    final top = _topPad;
    final chartW = size.width - _yAxisWidth;
    final chartH = size.height - _xLabelHeight - _topPad;

    final tp = TextPainter(textDirection: TextDirection.ltr);
    const labelStyle = TextStyle(fontSize: 10, color: Colors.grey);
    const valueStyle = TextStyle(fontSize: 9, color: Colors.black54, fontWeight: FontWeight.w600);

    // Y축 눈금 및 가로 격자
    final gridPaint = Paint()
      ..color = const Color(0xFFE8EEF7)
      ..strokeWidth = 1;
    const ticks = 3;
    for (int i = 1; i <= ticks; i++) {
      final val = (niceMax / ticks * i).roundToDouble();
      final y = _yOf(val, niceMax, top, chartH);
      canvas.drawLine(Offset(left, y), Offset(size.width, y), gridPaint);
      tp.text = TextSpan(text: val.toInt().toString(), style: labelStyle);
      tp.layout();
      tp.paint(canvas, Offset(left - tp.width - 4, y - tp.height / 2));
    }

    // 데이터 좌표 계산
    final n = labels.length;
    final drowsyPts = List.generate(
      drowsyData.length,
      (i) => Offset(_xOf(i, n, left, chartW), _yOf(drowsyData[i], niceMax, top, chartH)),
    );
    final phonePts = List.generate(
      phoneData.length,
      (i) => Offset(_xOf(i, n, left, chartW), _yOf(phoneData[i], niceMax, top, chartH)),
    );

    final drowsyPaint = Paint()
      ..color = _drowsyColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final phonePaint = Paint()
      ..color = _phoneColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // 스마트폰: 점선
    _drawDashed(canvas, phonePts, phonePaint);

    // 졸음: 실선
    if (drowsyPts.isNotEmpty) {
      final path = Path()..moveTo(drowsyPts[0].dx, drowsyPts[0].dy);
      for (int i = 1; i < drowsyPts.length; i++) {
        path.lineTo(drowsyPts[i].dx, drowsyPts[i].dy);
      }
      canvas.drawPath(path, drowsyPaint);
    }

    // 점 및 값 레이블 그리기
    void drawDots(List<Offset> pts, List<double> data, Color color) {
      final fill = Paint()..color = color..style = PaintingStyle.fill;
      final ring = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      for (int i = 0; i < pts.length; i++) {
        canvas.drawCircle(pts[i], 4, fill);
        canvas.drawCircle(pts[i], 4, ring);
        if (data[i] > 0) {
          tp.text = TextSpan(text: data[i].toInt().toString(), style: valueStyle);
          tp.layout();
          tp.paint(canvas, Offset(pts[i].dx - tp.width / 2, pts[i].dy - 14));
        }
      }
    }

    drawDots(phonePts, phoneData, _phoneColor);
    drawDots(drowsyPts, drowsyData, _drowsyColor);

    // X축 레이블
    for (int i = 0; i < labels.length; i++) {
      final x = _xOf(i, n, left, chartW);
      tp.text = TextSpan(text: labels[i], style: labelStyle);
      tp.layout();
      tp.paint(canvas, Offset(x - tp.width / 2, size.height - _xLabelHeight));
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter old) =>
      old.drowsyData != drowsyData ||
      old.phoneData != phoneData ||
      old.labels != labels;
}

class _DashLegendPainter extends CustomPainter {
  final Color color;
  const _DashLegendPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const dash = 4.0;
    const gap = 3.0;
    double x = 0;
    final y = size.height / 2;
    while (x < size.width) {
      final end = (x + dash).clamp(0.0, size.width);
      canvas.drawLine(Offset(x, y), Offset(end, y), paint);
      x = end + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashLegendPainter old) => old.color != color;
}
