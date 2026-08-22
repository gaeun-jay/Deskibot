import 'package:flutter/material.dart';
import 'package:deskibot/screens/home/home_screen.dart';
import 'package:deskibot/screens/focus/focus_screen.dart';
import 'package:deskibot/screens/timetable/timetable_screen.dart';
import 'package:deskibot/screens/daily_analysis/daily_analysis_screen.dart';
import 'package:deskibot/screens/cumulative_analysis/cumulative_analysis_screen.dart';
import 'package:deskibot/screens/settings/settings_screen.dart';
import 'package:deskibot/widgets/app_bottom_nav.dart';

class BottomBarScreen extends StatefulWidget {
  const BottomBarScreen({super.key});

  @override
  State<BottomBarScreen> createState() => _BottomBarScreenState();
}

class _BottomBarScreenState extends State<BottomBarScreen> {
  final List<Widget> _screens = const [
    HomeScreen(),
    FocusScreen(),
    TimetableScreen(),
    DailyAnalysisScreen(),
    CumulativeAnalysisScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // BottomNavState 가 유일한 소스다 — 다른 화면(카테고리 추가/수정 등)에서
    // 탭을 바꾸면 여기도 바로 다시 그려지게 구독한다.
    BottomNavState.index.addListener(_rebuild);
  }

  @override
  void dispose() {
    BottomNavState.index.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = BottomNavState.index.value;
    return Scaffold(
      body: IndexedStack(
        index: currentIndex,
        children: List.generate(
          _screens.length,
          (i) => TickerMode(enabled: i == currentIndex, child: _screens[i]),
        ),
      ),
      bottomNavigationBar: AppBottomNavBar(
        currentIndex: currentIndex,
        onTap: (index) => BottomNavState.index.value = index,
      ),
    );
  }
}
