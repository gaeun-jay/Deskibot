import 'package:flutter/material.dart';
import 'package:deskibot/screens/home/home_screen.dart';
import 'package:deskibot/screens/focus/focus_screen.dart';
import 'package:deskibot/screens/timetable/timetable_screen.dart';
import 'package:deskibot/screens/daily_analysis/daily_analysis_screen.dart';
import 'package:deskibot/screens/cumulative_analysis/cumulative_analysis_screen.dart';
import 'package:deskibot/screens/settings/settings_screen.dart';

class BottomBarScreen extends StatefulWidget {
  const BottomBarScreen({super.key});

  @override
  State<BottomBarScreen> createState() => _BottomBarScreenState();
}

class _BottomBarScreenState extends State<BottomBarScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    HomeScreen(),
    FocusScreen(),
    TimetableScreen(),
    DailyAnalysisScreen(),
    CumulativeAnalysisScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: List.generate(
          _screens.length,
          (i) => TickerMode(enabled: i == _currentIndex, child: _screens[i]),
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFF4A90D9),
        unselectedItemColor: Colors.grey,
        items: [
          BottomNavigationBarItem(
            icon: Image.asset(
              'assets/images/homebtn_none.png',
              width: 28,
              height: 28,
              color: Colors.grey,
              colorBlendMode: BlendMode.srcIn,
            ),
            activeIcon: Image.asset(
              'assets/images/homebtn_none.png',
              width: 28,
              height: 28,
              color: const Color(0xFF4A90D9),
              colorBlendMode: BlendMode.srcIn,
            ),
            label: '홈',
          ),
          BottomNavigationBarItem(
            icon: Image.asset(
              'assets/images/focusbtn_none.png',
              width: 28,
              height: 28,
              color: Colors.grey,
              colorBlendMode: BlendMode.srcIn,
            ),
            activeIcon: Image.asset(
              'assets/images/focusbtn_none.png',
              width: 28,
              height: 28,
              color: const Color(0xFF4A90D9),
              colorBlendMode: BlendMode.srcIn,
            ),
            label: '집중',
          ),
          BottomNavigationBarItem(
            icon: Image.asset(
              'assets/images/ttbtn_none.png',
              width: 28,
              height: 28,
              color: Colors.grey,
              colorBlendMode: BlendMode.srcIn,
            ),
            activeIcon: Image.asset(
              'assets/images/ttbtn_none.png',
              width: 28,
              height: 28,
              color: const Color(0xFF4A90D9),
              colorBlendMode: BlendMode.srcIn,
            ),
            label: '데일리로그',
          ),
          BottomNavigationBarItem(
            icon: Image.asset(
              'assets/images/dailybtn_none.png',
              width: 28,
              height: 28,
              color: Colors.grey,
              colorBlendMode: BlendMode.srcIn,
            ),
            activeIcon: Image.asset(
              'assets/images/dailybtn_none.png',
              width: 28,
              height: 28,
              color: const Color(0xFF4A90D9),
              colorBlendMode: BlendMode.srcIn,
            ),
            label: '일간',
          ),
          BottomNavigationBarItem(
            icon: Image.asset(
              'assets/images/cumbtn_none.png',
              width: 28,
              height: 28,
              color: Colors.grey,
              colorBlendMode: BlendMode.srcIn,
            ),
            activeIcon: Image.asset(
              'assets/images/cumbtn_none.png',
              width: 28,
              height: 28,
              color: const Color(0xFF4A90D9),
              colorBlendMode: BlendMode.srcIn,
            ),
            label: '누적',
          ),
          BottomNavigationBarItem(
            icon: Image.asset(
              'assets/images/setbtn_none.png',
              width: 28,
              height: 28,
              color: Colors.grey,
              colorBlendMode: BlendMode.srcIn,
            ),
            activeIcon: Image.asset(
              'assets/images/setbtn_none.png',
              width: 28,
              height: 28,
              color: const Color(0xFF4A90D9),
              colorBlendMode: BlendMode.srcIn,
            ),
            label: '설정',
          ),
        ],
      ),
    );
  }
}