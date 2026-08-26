import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' show min, max;
import 'package:deskibot/models/todo_model.dart';
import 'package:deskibot/models/focus_block_model.dart';
import 'package:deskibot/models/user_model.dart';
import 'package:deskibot/services/timetable_service.dart';
import 'package:deskibot/services/focus_session_service.dart';
import 'package:deskibot/theme/app_styles.dart';

// ── 색상 ─────────────────────────────────────────────────────────────
const _kPomoAccent = Color(0xFF1A6FDB);
const _kPomoBlock  = Color(0xFFE8F1FF);
const _kPomoText   = Color(0xFF1A4B8A);
const _kStopAccent = Color(0xFF4DA3FF);
const _kStopBlock  = Color(0xFFEDF5FF);
const _kStopText   = Color(0xFF1565C0);
// 자리 비움으로 강제 종료된 세션. 파랑 계열 사이에서 바로 눈에 띄도록 주황.
const _kInterruptAccent = Color(0xFFE8833A);
const _kPauseBg    = Color(0xFFE8EEF8);
const _kTrackBg    = Color(0xFFF9FAFE);
const _kTrackBdr   = Color(0xFFE8EEF8);
const _kHourLine   = Color(0xFFC8D8EF);
const _kMinLine    = Color(0xFFDCE8F5);
const _kTimeLabel  = Color(0xFFC7C7CC);
const _kMain       = Color(0xFF1A6FDB);
const _kDefaultColor = '#4A90D9';

Color _hexColor(String hex) =>
    Color(int.parse(hex.replaceFirst('#', '0xFF')));

String _minToHM(int m) =>
    '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

// 상세 패널용 12시간 형식 (예: "12:00 PM", "1:35 PM")
String _minTo12H(int m) {
  final h    = m ~/ 60;
  final min  = m % 60;
  final ampm = h < 12 ? 'AM' : 'PM';
  final h12  = h == 0 ? 12 : (h > 12 ? h - 12 : h);
  return '$h12:${min.toString().padLeft(2, '0')} $ampm';
}

String _hourLabel(int h) {
  if (h == 0) return '12AM';
  if (h < 12) return '${h}AM';
  if (h == 12) return '12PM';
  return '${h - 12}PM';
}

String _fmtDuration(int totalMin) {
  if (totalMin <= 0) return '-';
  if (totalMin < 60) return '$totalMin분';
  final h = totalMin ~/ 60;
  final m = totalMin % 60;
  return m > 0 ? '$h시간 $m분' : '$h시간';
}

// ══════════════════════════════════════════════════════════════════════
// 세그먼트 (활성 세션 or 일시정지 구간)
// ══════════════════════════════════════════════════════════════════════
class _Segment {
  final bool isActive;
  final int startMin;
  final int endMin;
  final FocusBlock? session; // isActive=true일 때만

  _Segment.active(FocusBlock s)
      : isActive = true,
        session = s,
        startMin = s.startMinutes,
        // endMinutes < startMinutes → 자정 넘김(또는 end_time null→00:00)
        // → 오늘 자정(24:00 = 1440분)으로 cap하여 양수 duration 보장
        endMin = s.endMinutes >= s.startMinutes ? s.endMinutes : 24 * 60;

  /// 세션 내부 일시정지 분리용: endMin을 activeEnd로 잘라서 표현
  _Segment.activePart(FocusBlock s, int activeEnd)
      : isActive = true,
        session = s,
        startMin = s.startMinutes,
        endMin = activeEnd;

  _Segment.pause({required this.startMin, required this.endMin})
      : isActive = false,
        session = null;

  int get durationMin => endMin - startMin;
}

// ══════════════════════════════════════════════════════════════════════
// 세션 그룹 (9분 이내 병합 + 세그먼트 자동 생성)
// ══════════════════════════════════════════════════════════════════════
class _SessionGroup {
  final List<FocusBlock> sessions;
  late final List<_Segment> segments;

  _SessionGroup(this.sessions) {
    final sorted = List<FocusBlock>.from(sessions)
      ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
    final segs = <_Segment>[];
    for (int i = 0; i < sorted.length; i++) {
      // 세션 간 갭 → 일시정지 세그먼트 (스톱워치만; 뽀모도로는 세션 사이 갭 표시 안 함)
      if (i > 0 && sorted[0].sessionType != 'pomodoro') {
        final prevEnd  = sorted[i - 1].endMinutes;
        final curStart = sorted[i].startMinutes;
        if (curStart > prevEnd) {
          segs.add(_Segment.pause(startMin: prevEnd, endMin: curStart));
        }
      }

      final fb = sorted[i];
      final totalMin  = (fb.endMinutes - fb.startMinutes).clamp(0, 24 * 60);
      final activeMin = fb.durationMin;

      // 뽀모도로는 일시정지가 없으므로 내부 pause 세그먼트를 만들지 않는다.
      if (activeMin > 0 && activeMin < totalMin &&
          sorted[0].sessionType != 'pomodoro') {
        // 세션 내부 일시정지 감지 (actual_duration < total_duration, 스톱워치만)
        // 활성 구간: startMin ~ startMin+activeMin
        // 일시정지:  startMin+activeMin ~ endMin
        final activeEnd = fb.startMinutes + activeMin;
        segs.add(_Segment.activePart(fb, activeEnd));
        segs.add(_Segment.pause(startMin: activeEnd, endMin: fb.endMinutes));
      } else {
        segs.add(_Segment.active(fb));
      }
    }
    segments = segs;
  }

  int get startMinutes => segments.first.startMin;
  int get endMinutes   => segments.last.endMin;

  String get sessionType {
    final t = sessions.map((s) => s.sessionType).toSet();
    return t.length == 1 ? t.first : 'mixed';
  }

  String get displayLabel {
    final typeName = sessionType == 'pomodoro' ? '뽀모도로' : '스톱워치';
    if (sessions.length == 1) {
      final lbl = sessions.first.label;
      const defaults = {'집중 세션', '뽀모도로 세션', '스톱워치 세션', ''};
      if (defaults.contains(lbl)) return typeName;
      return lbl;
    }
    return typeName;
  }

  int get totalDuration =>
      segments.where((s) => s.isActive).fold(0, (sum, s) => sum + s.durationMin);

  String get key => sessions.map((s) => s.id).join('|');
}

List<_SessionGroup> _mergeSessions(List<FocusBlock> blocks) {
  if (blocks.isEmpty) return [];
  blocks.sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
  final groups = <_SessionGroup>[];
  var cur = <FocusBlock>[blocks.first];
  for (int i = 1; i < blocks.length; i++) {
    final curEnd = cur.map((s) => s.endMinutes).reduce(max);
    final next = blocks[i];
    if (next.startMinutes - curEnd <= 9) {
      cur.add(next);
    } else {
      groups.add(_SessionGroup(cur));
      cur = [next];
    }
  }
  groups.add(_SessionGroup(cur));
  return groups;
}

// ══════════════════════════════════════════════════════════════════════
// 압축 타임라인 매퍼
// ══════════════════════════════════════════════════════════════════════
class _TSpan {
  final bool isGap;
  final int startMin;
  final int endMin;
  _TSpan.active(this.startMin, this.endMin) : isGap = false;
  _TSpan.gap(this.startMin, this.endMin)    : isGap = true;
}

class _TimelineMapper {
  static const double hourH = 80.0;
  static const double gapH  = 30.0;

  final List<_TSpan> spans;
  _TimelineMapper(this.spans);

  factory _TimelineMapper.fromGroups(
      List<_SessionGroup> pomo, List<_SessionGroup> stop) {
    final all = [...pomo, ...stop];
    if (all.isEmpty) {
      return _TimelineMapper([
        _TSpan.gap(0, 9 * 60),
        _TSpan.active(9 * 60, 18 * 60),
        _TSpan.gap(18 * 60, 24 * 60),
      ]);
    }
    final ranges = <List<int>>[];
    for (final g in all) {
      final s = max(0,       g.startMinutes ~/ 60 - 1) * 60;
      final e = min(24 * 60, ((g.endMinutes + 59) ~/ 60 + 1) * 60);
      ranges.add([s, e]);
    }
    ranges.sort((a, b) => a[0].compareTo(b[0]));
    final merged = [ranges.first.toList()];
    for (int i = 1; i < ranges.length; i++) {
      if (ranges[i][0] <= merged.last[1]) {
        merged.last[1] = max(merged.last[1], ranges[i][1]);
      } else {
        merged.add(ranges[i].toList());
      }
    }
    final spans = <_TSpan>[];
    int pos = 0;
    for (final r in merged) {
      if (r[0] > pos) spans.add(_TSpan.gap(pos, r[0]));
      spans.add(_TSpan.active(r[0], r[1]));
      pos = r[1];
    }
    if (pos < 24 * 60) spans.add(_TSpan.gap(pos, 24 * 60));
    return _TimelineMapper(spans);
  }

  double get totalHeight {
    double h = 0;
    for (final s in spans) {
      h += s.isGap ? gapH : (s.endMin - s.startMin) * hourH / 60;
    }
    return h;
  }

  double minutesToY(int minutes) {
    double y = 0;
    for (final s in spans) {
      if (minutes <= s.startMin) return y;
      if (minutes >= s.endMin) {
        y += s.isGap ? gapH : (s.endMin - s.startMin) * hourH / 60;
        continue;
      }
      if (s.isGap) return y + gapH / 2;
      return y + (minutes - s.startMin) * hourH / 60;
    }
    return y;
  }

  double spanStartY(_TSpan target) {
    double y = 0;
    for (final s in spans) {
      if (identical(s, target)) return y;
      y += s.isGap ? gapH : (s.endMin - s.startMin) * hourH / 60;
    }
    return y;
  }
}

// ══════════════════════════════════════════════════════════════════════
// 화면
// ══════════════════════════════════════════════════════════════════════
class TimetableScreen extends StatefulWidget {
  const TimetableScreen({super.key});
  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  final _service = TimetableService();

  DateTime _selectedDate = DateTime.now();
  int _selectedTab = 0; // 0 = 집중 세션, 1 = Todo

  List<TodoModel>  _todos       = [];
  List<FocusBlock> _focusBlocks = [];
  Map<String, Category> _categories = {};
  bool _isLoading  = true;
  bool _wasVisible = false;
  StreamSubscription? _sessionSub;

  // 캐싱된 세션 그룹
  List<_SessionGroup> _pomoGroups = [];
  List<_SessionGroup> _stopGroups = [];

  // 상세 패널 상태
  _SessionGroup? _selectedGroup;
  String?        _selectedGroupKey;
  bool           _editMode = false;
  final Set<String> _selectedIds = {};
  final _nameCtrl = TextEditingController();
  bool _isSaving  = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));
    _loadData();
    // 세션 종료 시 타임테이블 자동 갱신
    _sessionSub = FocusSessionService().getTodaySessions().listen((_) {
      if (_selectedDate.day == DateTime.now().day) _loadData();
    });
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    _nameCtrl.dispose();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ));
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = TickerMode.valuesOf(context).enabled;
    if (v && !_wasVisible) _loadData();
    _wasVisible = v;
  }

  String get _dateKey {
    final d = _selectedDate;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String get _dateLabel {
    final now = DateTime.now();
    final today = _selectedDate.year == now.year &&
        _selectedDate.month == now.month &&
        _selectedDate.day == now.day;
    final s = '${_selectedDate.month}월 ${_selectedDate.day}일';
    return today ? '$s (오늘)' : s;
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final res = await Future.wait([
      _service.getTodosForDate(_dateKey),
      _service.getFocusBlocksForDate(_dateKey),
      _service.getCategories(),
    ]);
    if (!mounted) return;
    final blocks = res[1] as List<FocusBlock>;
    setState(() {
      _todos       = res[0] as List<TodoModel>;
      _focusBlocks = blocks;
      _categories  = res[2] as Map<String, Category>;
      _pomoGroups  = _computeGroups('pomodoro');
      _stopGroups  = _computeGroups('stopwatch');
      _isLoading   = false;
      // 데이터 갱신 시 선택 상태 초기화
      _selectedGroup    = null;
      _selectedGroupKey = null;
      _editMode         = false;
      _selectedIds.clear();
    });
  }

  List<_SessionGroup> _computeGroups(String type) {
    final blocks = _focusBlocks
        .where((b) => b.sessionType == type)
        // 실제 실행 시간(일시정지 제외)이 10분 미만인 세션은 시각화하지 않음
        .where((b) => b.durationMin >= 10)
        .toList();
    return _mergeSessions(blocks);
  }

  // ── 이벤트 핸들러 ──────────────────────────────────────────────────
  void _selectGroup(_SessionGroup g) {
    setState(() {
      if (_selectedGroupKey == g.key) {
        // 같은 블록 재탭 → 닫기
        _selectedGroup    = null;
        _selectedGroupKey = null;
      } else {
        _selectedGroup    = g;
        _selectedGroupKey = g.key;
      }
      _editMode = false;
      _selectedIds.clear();
      _nameCtrl.clear();
    });
  }

  void _closeDetail() {
    setState(() {
      _selectedGroup    = null;
      _selectedGroupKey = null;
      _editMode         = false;
      _selectedIds.clear();
      _nameCtrl.clear();
    });
  }

  void _enterEditMode() {
    setState(() {
      _editMode = true;
      _selectedIds.clear();
      _nameCtrl.clear();
    });
  }

  void _cancelEdit() {
    setState(() {
      _editMode = false;
      _selectedIds.clear();
      _nameCtrl.clear();
    });
  }

  void _toggleSession(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _applyName() async {
    final label = _nameCtrl.text.trim();
    if (label.isEmpty || _selectedIds.isEmpty) return;
    setState(() => _isSaving = true);
    await Future.wait(
        _selectedIds.map((id) => _service.updateFocusLabel(id, label)));
    if (!mounted) return;
    setState(() => _isSaving = false);
    _cancelEdit();
    _loadData();
  }

  void _showDeadlineSheet(TodoModel todo) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) =>
          _DeadlineSheet(todo: todo, service: _service, onSaved: _loadData),
    );
  }

  // ── 빌드 ───────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final sbH    = MediaQuery.of(context).padding.top;
    final headerH = sbH + 150.0;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F4FF),
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(gradient: kAppBackgroundGradient),
            ),
          ),
          Positioned(
            top: sbH + 16, left: 10,
            child: Image.asset('assets/images/character_timetable.png',
                width: 143, height: 143, fit: BoxFit.contain),
          ),
          Positioned(
            top: sbH + 70, left: 155, right: 16,
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Daily Log', style: kHeaderTitleStyle),
                SizedBox(height: 6),
                Text('하루 일정을 시간대별로 확인하세요.',
                    style: kHeaderSubtitleStyle),
              ],
            ),
          ),
          Positioned(
            top: headerH, left: 14, right: 14, bottom: 0,
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
                      offset: Offset(0, -4)),
                ],
              ),
              child: Column(
                children: [
                  // 날짜 네비게이션
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
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
                        GestureDetector(
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _selectedDate,
                              firstDate: DateTime(2024),
                              lastDate: DateTime.now(),
                            );
                            if (picked != null) {
                              setState(() => _selectedDate = picked);
                              _loadData();
                            }
                          },
                          child: Text(_dateLabel,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1E1E1E))),
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
                  // 탭 전환
                  _TabSwitcher(
                    selectedIndex: _selectedTab,
                    onChanged: (i) => setState(() {
                      _selectedTab = i;
                      _closeDetail();
                    }),
                    labels: const ['집중 세션', 'Todo'],
                  ),
                  // 콘텐츠
                  Expanded(
                    child: _isLoading
                        ? const Center(
                            child: CircularProgressIndicator(color: _kMain))
                        : _selectedTab == 0
                            ? _buildFocusTab()
                            : _TodoListSection(
                                todos: _todos,
                                categories: _categories,
                                onToggle: (t) async {
                                  await _service.toggleDone(t.id, !t.isDone);
                                  _loadData();
                                },
                                onDelete: (t) async {
                                  await _service.deleteTodo(t.id);
                                  _loadData();
                                },
                                onSetDeadline: _showDeadlineSheet,
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

  // ══════════════════════════════════════════════════════════════════
  // 집중 세션 탭
  // ══════════════════════════════════════════════════════════════════
  Widget _buildFocusTab() {
    if (_pomoGroups.isEmpty && _stopGroups.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, size: 48, color: Color(0xFFCCCCCC)),
            SizedBox(height: 12),
            Text('집중 세션 기록이 없어요',
                style: TextStyle(fontSize: 15, color: Color(0xFFAAAAAA))),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 힌트
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Text(
            '타임라인  ›  블록 탭해서 상세보기',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF8E8E93)),
          ),
        ),
        // 트랙 (스크롤)
        Expanded(
          child: LayoutBuilder(builder: (ctx, bc) {
            final totalW = bc.maxWidth;
            final mapper = _TimelineMapper.fromGroups(_pomoGroups, _stopGroups);
            return _buildTracks(totalW, mapper);
          }),
        ),
        // 범례
        _buildLegend(),
        // 상세 패널
        _buildDetailPanel(),
      ],
    );
  }

  // ── 트랙 영역 ──────────────────────────────────────────────────────
  Widget _buildTracks(double totalW, _TimelineMapper mapper) {
    const timeW  = 44.0;
    const gapW   = 6.0;
    const labelH = 22.0;
    final trackW = (totalW - timeW - gapW) / 2;
    final pomoX  = timeW;
    final stopX  = timeW + trackW + gapW;
    final totalH = labelH + mapper.totalHeight + _kRunMinH + 8;

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: SizedBox(
        width: totalW,
        height: totalH,
        child: Stack(
          children: [
            // 트랙 컬럼 레이블
            Positioned(
              top: 0, left: pomoX, width: trackW, height: labelH,
              child: Center(
                child: Text('뽀모도로',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _kPomoAccent.withValues(alpha: 0.7))),
              ),
            ),
            Positioned(
              top: 0, left: stopX, width: trackW, height: labelH,
              child: Center(
                child: Text('스톱워치',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _kStopAccent.withValues(alpha: 0.7))),
              ),
            ),
            // 시간 레이블 컬럼
            Positioned(
              top: labelH, left: 0, width: timeW, height: mapper.totalHeight,
              child: Stack(children: _buildTimeCol(mapper)),
            ),
            // 뽀모도로 트랙
            Positioned(
              top: labelH, left: pomoX, width: trackW, height: mapper.totalHeight,
              child: _buildTrackWidget(_pomoGroups, mapper,
                  _kPomoAccent, _kPomoBlock, _kPomoText),
            ),
            // 스톱워치 트랙
            Positioned(
              top: labelH, left: stopX, width: trackW, height: mapper.totalHeight,
              child: _buildTrackWidget(_stopGroups, mapper,
                  _kStopAccent, _kStopBlock, _kStopText),
            ),
          ],
        ),
      ),
    );
  }

  // ── 시간 레이블 컬럼 ────────────────────────────────────────────────
  List<Widget> _buildTimeCol(_TimelineMapper mapper) {
    final ws = <Widget>[];
    for (final span in mapper.spans) {
      final sy = mapper.spanStartY(span);
      if (span.isGap) {
        ws.add(Positioned(
          top: sy, left: 0, right: 0, height: _TimelineMapper.gapH,
          child: Center(
            child: Text(
              '${_hourLabel(span.startMin ~/ 60)} … ${_hourLabel(span.endMin ~/ 60)}',
              style: const TextStyle(fontSize: 9, color: _kTimeLabel),
              textAlign: TextAlign.center,
            ),
          ),
        ));
      } else {
        for (int m = span.startMin; m < span.endMin; m += 60) {
          final y = mapper.minutesToY(m);
          ws.add(Positioned(
            top: y - 7, left: 0, right: 4,
            child: Text(
              _hourLabel(m ~/ 60),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 10, color: _kTimeLabel),
            ),
          ));
        }
      }
    }
    return ws;
  }

  // ── 단일 트랙 위젯 ──────────────────────────────────────────────────
  Widget _buildTrackWidget(
    List<_SessionGroup> groups,
    _TimelineMapper mapper,
    Color accent,
    Color blockBg,
    Color textColor,
  ) {
    return Stack(
      clipBehavior: Clip.none, // 자정 근처 블록이 잘리지 않도록
      children: [
        // 트랙 배경
        Container(
          decoration: BoxDecoration(
            color: _kTrackBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _kTrackBdr, width: 0.5),
          ),
        ),
        // 시간선
        ..._buildTrackLines(mapper),
        // 세션 블록
        ..._buildBlocks(groups, mapper, accent, textColor),
      ],
    );
  }

  // ── 트랙 격자선 ────────────────────────────────────────────────────
  List<Widget> _buildTrackLines(_TimelineMapper mapper) {
    final ws = <Widget>[];
    for (final span in mapper.spans) {
      if (span.isGap) continue;
      for (int m = span.startMin; m < span.endMin; m += 60) {
        final y = mapper.minutesToY(m);
        ws.add(Positioned(
          top: y, left: 0, right: 0, height: 1,
          child: const ColoredBox(color: _kHourLine),
        ));
        for (int dm = 10; dm < 60; dm += 10) {
          final m10 = m + dm;
          if (m10 < span.endMin) {
            ws.add(Positioned(
              top: mapper.minutesToY(m10), left: 0, right: 0, height: 1,
              child: const ColoredBox(color: _kMinLine),
            ));
          }
        }
      }
    }
    return ws;
  }

  // ── 세션 블록 렌더링 ────────────────────────────────────────────────
  // • 그룹 전체(시작~끝)를 하나의 블록으로 렌더링
  // • 활성 구간: solid accent 스트립
  // • 일시정지 구간: 연한 accent 배경으로 자동 시각화 (빈 공간 없이)
  // • 최소 높이 클램프 + 그룹 간 최소 간격 유지
  static const double _kRunMinH   = 24.0; // 블록 최소 높이 (px)
  static const double _kPauseGap  =  5.0; // 블록 사이 최소 간격 (px)

  List<Widget> _buildBlocks(
    List<_SessionGroup> groups,
    _TimelineMapper mapper,
    Color accent,
    Color textColor,
  ) {
    final ws = <Widget>[];
    double prevBottom = double.negativeInfinity;

    for (final g in groups) {
      final isSel = _selectedGroupKey == g.key;

      // ── 그룹 전체 위치 계산 ──────────────────────────────────────────
      final naturalTop = mapper.minutesToY(g.startMinutes);
      final naturalBot = mapper.minutesToY(g.endMinutes);
      final bH = (naturalBot - naturalTop).clamp(_kRunMinH, double.infinity);

      // 이전 블록과 겹치면 아래로 밀기
      final bTop = (prevBottom.isFinite && prevBottom + _kPauseGap > naturalTop)
          ? prevBottom + _kPauseGap
          : naturalTop;
      prevBottom = bTop + bH;

      // ── 일시정지 유무에 따라 렌더링 방식 분기 ───────────────────────
      // 일시정지 없음: 블록 전체를 solid accent로 채움
      // 일시정지 있음: 세그먼트 위치를 bH에 비례 스케일 → 항상 블록을 꽉 채움
      //   (짧은 세션이 _kRunMinH로 늘어나도 active/pause 비율을 유지)
      final hasPause   = g.segments.any((s) => !s.isActive);
      final naturalBH  = naturalBot - naturalTop; // 실제 픽셀 높이 (< _kRunMinH 가능)
      // 스케일: bH / naturalBH. naturalBH=0 이면 스케일 불필요
      final scale      = (hasPause && naturalBH > 0) ? bH / naturalBH : 1.0;

      // 활성 구간 스트립 (일시정지 있을 때만, 비례 스케일 적용)
      final activeStrips = !hasPause ? <Widget>[] :
          g.segments.where((s) => s.isActive).map((seg) {
            final segNatTop = mapper.minutesToY(seg.startMin) - naturalTop;
            final segNatH   = mapper.minutesToY(seg.endMin)
                            - mapper.minutesToY(seg.startMin);
            final segTop = (segNatTop * scale).clamp(0.0, bH);
            final segH   = (segNatH  * scale).clamp(2.0, bH - segTop);
            // 세그먼트마다 따로 칠한다. 9분 이내 세션은 한 블록으로 병합되므로
            // 정상 종료와 자리 비움 종료가 같은 블록에 섞일 수 있다.
            final segColor = seg.session?.isInterrupted == true
                ? _kInterruptAccent
                : accent;
            return Positioned(
              top: segTop, left: 0, right: 0, height: segH,
              child: ColoredBox(color: segColor),
            );
          }).toList();

      // 일시정지가 없어 블록을 한 색으로 칠하는 경우의 색.
      // 이 경로는 세그먼트가 사실상 하나라, 그 세션의 상태를 그대로 따른다.
      final solidColor = g.sessions.every((s) => s.isInterrupted)
          ? _kInterruptAccent
          : accent;

      ws.add(Positioned(
        top: bTop, left: 3, right: 3, height: bH,
        child: GestureDetector(
          onTap: () => _selectGroup(g),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ① 배경: 일시정지 없으면 solid, 있으면 연한 accent(pause 영역)
                ColoredBox(color: hasPause
                    ? accent.withValues(alpha: 0.20)
                    : solidColor),
                // ② 활성 구간 스트립
                ...activeStrips,
                // ③ 이름 배지: HTML 목업의 .block-name-tag 방식
                //    rgba(255,255,255,0.22) 반투명 흰 pill → active·pause 어떤 배경 위에도 가독성 확보
                //    width=fit-content: 텍스트 너비만큼만 (Row+Flexible로 구현)
                Positioned(
                  top: 4, left: 5, right: 5,
                  child: Row(
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            g.displayLabel,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // ④ 시간 범위 (블록이 넉넉할 때)
                if (bH >= 52)
                  Positioned(
                    bottom: 4, left: 5, right: 5,
                    child: Text(
                      '${_minToHM(g.startMinutes)}–${_minToHM(g.endMinutes)}',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                // ⑤ 선택 표시: 흰색 내부 테두리
                if (isSel)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.9),
                            width: 2.5,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ));

      // ⑥ 선택 시 외부 accent 테두리
      if (isSel) {
        ws.add(Positioned(
          top: bTop - 2, left: 1, right: 1, height: bH + 4,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: accent, width: 2),
              ),
            ),
          ),
        ));
      }
    }
    return ws;
  }

  // ── 범례 ───────────────────────────────────────────────────────────
  Widget _buildLegend() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _LegendItem(color: _kPomoAccent, label: '뽀모도로'),
          const SizedBox(width: 16),
          _LegendItem(color: _kStopAccent, label: '스톱워치'),
          const SizedBox(width: 16),
          _LegendItem(color: _kInterruptAccent, label: '자리비움 종료'),
          const SizedBox(width: 16),
          _LegendItem(
              color: _kPauseBg,
              label: '일시정지',
              bordered: true),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // 상세 패널 (인라인)
  // ══════════════════════════════════════════════════════════════════
  Widget _buildDetailPanel() {
    final g = _selectedGroup;
    final isPomo    = g?.sessionType == 'pomodoro';
    final accent    = isPomo ? _kPomoAccent : _kStopAccent;
    final typeName  = isPomo ? '뽀모도로' : '스톱워치';
    final title     = g == null ? '블록을 탭하세요' : '$typeName 세션 로그';

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE5E5EA), width: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 헤더
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: g != null
                  ? const Color(0xFFF8FAFF)
                  : const Color(0xFFFAFAFA),
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(13)),
              border: const Border(
                  bottom: BorderSide(color: Color(0xFFE5E5EA), width: 0.5)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: g != null ? accent : const Color(0xFF8E8E93),
                    ),
                  ),
                ),
                if (g != null) ...[
                  if (!_editMode)
                    GestureDetector(
                      onTap: _enterEditMode,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2F7FF),
                          border: Border.all(
                              color: const Color(0xFFB5D4F4), width: 0.5),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('변경',
                            style: TextStyle(
                                fontSize: 12, color: accent)),
                      ),
                    ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _closeDetail,
                    child: const Text('닫기',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFF8E8E93))),
                  ),
                ],
              ],
            ),
          ),
          // 바디
          g == null
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: Text(
                      '타임라인에서 블록을 탭하세요',
                      style: TextStyle(
                          fontSize: 13, color: Color(0xFFC7C7CC)),
                    ),
                  ),
                )
              : _buildDetailBody(g),
        ],
      ),
    );
  }

  Widget _buildDetailBody(_SessionGroup g) {
    int activeIdx = 0;
    final isPomo  = g.sessionType == 'pomodoro';
    final accent  = isPomo ? _kPomoAccent : _kStopAccent;
    final dotClass = isPomo ? _kPomoAccent : _kStopAccent;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_editMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
            child: Text(
              '활성 로그를 선택하고 이름을 입력하세요',
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFF8E8E93)),
            ),
          ),
        // 세그먼트 로그 리스트
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: g.segments.length,
            itemBuilder: (ctx, i) {
              final seg = g.segments[i];
              if (!seg.isActive) {
                // ── 일시정지 행 ──────────────────────────────
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: const BoxDecoration(
                    color: Color(0xFFF7F9FC),
                    border: Border(
                        bottom: BorderSide(
                            color: Color(0xFFF0F0F5), width: 0.5)),
                  ),
                  child: Row(
                    children: [
                      // "—" 대시
                      const SizedBox(
                        width: 26,
                        child: Text('—',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFFB0B0B0))),
                      ),
                      const SizedBox(width: 6),
                      // 회색 원형 점
                      Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFFCCCCCC),
                            shape: BoxShape.circle,
                          )),
                      const SizedBox(width: 8),
                      // 라벨
                      const Expanded(
                        child: Text('일시정지',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFFAAAAAA),
                              fontStyle: FontStyle.italic,
                            )),
                      ),
                      // 시작 시간 (12시간 형식)
                      Text(_minTo12H(seg.startMin),
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFFAAAAAA))),
                      const SizedBox(width: 8),
                      // 소요 시간 pill
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0F0F5),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          _fmtDuration(seg.durationMin),
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFFBBBBBB)),
                        ),
                      ),
                    ],
                  ),
                );
              }

              // ── 활성 세션 행 ─────────────────────────────
              activeIdx++;
              final num     = activeIdx;
              final session = seg.session!;
              final isChecked = _selectedIds.contains(session.id);
              const defaults = {'집중 세션', '뽀모도로 세션', '스톱워치 세션', ''};
              final rowLabel = defaults.contains(session.label)
                  ? (isPomo ? '뽀모도로' : '스톱워치')
                  : session.label;

              return GestureDetector(
                onTap: _editMode ? () => _toggleSession(session.id) : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: (_editMode && isChecked)
                        ? const Color(0xFFE8F0FF)
                        : Colors.white,
                    border: const Border(
                        bottom: BorderSide(
                            color: Color(0xFFF2F2F7), width: 0.5)),
                  ),
                  child: Row(
                    children: [
                      // 번호 or 체크박스
                      SizedBox(
                        width: 26,
                        child: _editMode
                            ? AnimatedContainer(
                                duration: const Duration(milliseconds: 120),
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isChecked
                                      ? accent
                                      : Colors.transparent,
                                  border: Border.all(
                                    color: isChecked
                                        ? accent
                                        : const Color(0xFFB5D4F4),
                                    width: 1.5,
                                  ),
                                ),
                                child: isChecked
                                    ? const Icon(Icons.check,
                                        size: 11, color: Colors.white)
                                    : null,
                              )
                            : Text(
                                '$num',
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFFB0B0B0)),
                              ),
                      ),
                      const SizedBox(width: 6),
                      // 색상 원형 점 — 자리 비움으로 끊긴 세션은 주황
                      Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: session.isInterrupted
                                ? _kInterruptAccent
                                : dotClass,
                            shape: BoxShape.circle,
                          )),
                      const SizedBox(width: 8),
                      // 이름 — 자리 비움으로 끊긴 세션은 주황
                      Flexible(
                        child: Text(
                          rowLabel,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: session.isInterrupted
                                  ? _kInterruptAccent
                                  : const Color(0xFF1E1E1E)),
                        ),
                      ),
                      // 미완료 배지.
                      // 블록이 9분 이내로 병합되면 목록에서 어느 세션이 자리
                      // 비움으로 끊긴 건지 알아볼 방법이 없어 글자로 남긴다.
                      if (session.isInterrupted) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: _kInterruptAccent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '미완료',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: _kInterruptAccent),
                          ),
                        ),
                      ],
                      const Spacer(),
                      // 시작 시간 (12시간 형식)
                      Text(_minTo12H(seg.startMin),
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF8E8E93))),
                      const SizedBox(width: 8),
                      // 소요 시간 pill — 자리 비움 세션은 주황 계열로
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: session.isInterrupted
                              ? _kInterruptAccent.withValues(alpha: 0.10)
                              : const Color(0xFFF0F4FF),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: session.isInterrupted
                                  ? _kInterruptAccent.withValues(alpha: 0.35)
                                  : const Color(0xFFDCE8FF),
                              width: 0.5),
                        ),
                        child: Text(
                          _fmtDuration(seg.durationMin),
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: session.isInterrupted
                                  ? _kInterruptAccent
                                  : const Color(0xFF6E8EC4)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        // 편집 바
        if (_editMode)
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFF),
              border: Border(
                  top: BorderSide(color: Color(0xFFE5E5EA), width: 0.5)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameCtrl,
                    autofocus: false,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '이름 입력 (예: 알고리즘 공부)',
                      hintStyle: const TextStyle(
                          fontSize: 13, color: Color(0xFFAAAAAA)),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: Color(0xFFB5D4F4), width: 0.5),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: Color(0xFFB5D4F4), width: 0.5),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: _kMain, width: 1),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: _cancelEdit,
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 7)),
                  child: const Text('취소',
                      style: TextStyle(
                          fontSize: 13, color: Color(0xFF8E8E93))),
                ),
                const SizedBox(width: 4),
                ElevatedButton(
                  onPressed: (_isSaving ||
                          _selectedIds.isEmpty ||
                          _nameCtrl.text.trim().isEmpty)
                      ? null
                      : _applyName,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _kMain,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 7),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Text('적용',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// 범례 아이템
// ══════════════════════════════════════════════════════════════════════
class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  final bool bordered;
  const _LegendItem(
      {required this.color, required this.label, this.bordered = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border: bordered
                ? Border.all(color: const Color(0xFFD0DAEA), width: 0.5)
                : null,
          ),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF8E8E93))),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// 탭 전환 버튼
// ══════════════════════════════════════════════════════════════════════
class _TabSwitcher extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final List<String> labels;

  const _TabSwitcher(
      {required this.selectedIndex,
      required this.onChanged,
      required this.labels});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: const Color(0xFFF0F4FF),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: List.generate(labels.length, (i) {
            final sel = i == selectedIndex;
            return Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: sel ? _kMain : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: sel ? Colors.white : const Color(0xFF888888),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Todo 체크리스트 섹션
// ══════════════════════════════════════════════════════════════════════
class _TodoListSection extends StatelessWidget {
  final List<TodoModel> todos;
  final Map<String, Category> categories;
  final ValueChanged<TodoModel> onToggle;
  final ValueChanged<TodoModel> onDelete;
  final ValueChanged<TodoModel> onSetDeadline;

  const _TodoListSection({
    required this.todos,
    required this.categories,
    required this.onToggle,
    required this.onDelete,
    required this.onSetDeadline,
  });

  @override
  Widget build(BuildContext context) {
    if (todos.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 48, color: Color(0xFFCCCCCC)),
            SizedBox(height: 12),
            Text('오늘의 할 일이 없어요',
                style: TextStyle(fontSize: 15, color: Color(0xFFAAAAAA))),
          ],
        ),
      );
    }
    final undone = todos.where((t) => !t.isDone).toList();
    final done   = todos.where((t) =>  t.isDone).toList();
    final sorted = [...undone, ...done];

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      itemCount: sorted.length,
      separatorBuilder: (context, index) =>
          const Divider(height: 1, thickness: 1, color: Color(0xFFF0F0F0)),
      itemBuilder: (ctx, i) {
        final todo = sorted[i];
        final chipColor = _hexColor(
            categories[todo.categoryId]?.color ?? _kDefaultColor);
        return _TodoTile(
          todo: todo,
          categoryName: categories[todo.categoryId]?.name,
          chipColor: chipColor,
          onToggle: () => onToggle(todo),
          onDelete: () => onDelete(todo),
          onSetDeadline: () => onSetDeadline(todo),
        );
      },
    );
  }
}

class _TodoTile extends StatelessWidget {
  final TodoModel todo;
  final String? categoryName;
  final Color chipColor;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onSetDeadline;

  const _TodoTile({
    required this.todo,
    required this.categoryName,
    required this.chipColor,
    required this.onToggle,
    required this.onDelete,
    required this.onSetDeadline,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () => _showOptions(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: onToggle,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: todo.isDone ? _kMain : Colors.transparent,
                  border: Border.all(
                    color: todo.isDone ? _kMain : const Color(0xFFCCCCCC),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: todo.isDone
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
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
                  if (todo.deadlineTime != null) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.schedule,
                            size: 12, color: Color(0xFF888888)),
                        const SizedBox(width: 3),
                        Text('마감 ${todo.deadlineTime}',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF888888))),
                      ],
                    ),
                  ],
                ],
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
                      color: chipColor),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showOptions(BuildContext context) {
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
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(todo.content,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.schedule, color: _kMain),
              title: const Text('마감 시간 설정'),
              onTap: () {
                Navigator.pop(context);
                onSetDeadline();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: Color(0xFFE74C3C)),
              title: const Text('삭제',
                  style: TextStyle(color: Color(0xFFE74C3C))),
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

// ══════════════════════════════════════════════════════════════════════
// 마감 시간 바텀시트
// ══════════════════════════════════════════════════════════════════════
class _DeadlineSheet extends StatefulWidget {
  final TodoModel todo;
  final TimetableService service;
  final VoidCallback onSaved;

  const _DeadlineSheet(
      {required this.todo, required this.service, required this.onSaved});

  @override
  State<_DeadlineSheet> createState() => _DeadlineSheetState();
}

class _DeadlineSheetState extends State<_DeadlineSheet> {
  String? _deadlineTime;

  @override
  void initState() {
    super.initState();
    _deadlineTime = widget.todo.deadlineTime;
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pick() async {
    final init = _deadlineTime != null
        ? TimeOfDay(
            hour:   int.parse(_deadlineTime!.split(':')[0]),
            minute: int.parse(_deadlineTime!.split(':')[1]))
        : TimeOfDay.now();
    final p = await showTimePicker(context: context, initialTime: init);
    if (p != null) setState(() => _deadlineTime = _fmt(p));
  }

  Future<void> _save() async {
    await widget.service.updateDeadlineTime(widget.todo.id, _deadlineTime);
    if (!mounted) return;
    Navigator.pop(context);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    final hasV = _deadlineTime != null;
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
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const Text('마감 시간 설정',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(widget.todo.content,
              style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _pick,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(
                    color: hasV ? _kMain : const Color(0xFFCCCCCC)),
                borderRadius: BorderRadius.circular(10),
                color: hasV ? const Color(0xFFEEF4FF) : Colors.white,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.schedule,
                      size: 18,
                      color: hasV ? _kMain : const Color(0xFF888888)),
                  const SizedBox(width: 8),
                  Text(
                    hasV ? _deadlineTime! : '마감 시간 선택',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: hasV ? FontWeight.w600 : FontWeight.normal,
                      color: hasV ? _kMain : const Color(0xFF888888),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (hasV)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _deadlineTime = null),
                child: const Text('마감 시간 제거',
                    style:
                        TextStyle(color: Color(0xFF888888), fontSize: 13)),
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kMain,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('저장',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
