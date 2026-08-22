import 'package:flutter/material.dart';

/// 현재 선택된 하단 탭 인덱스.
///
/// BottomBarScreen 의 IndexedStack 밖에서 Navigator.push 로 띄운 화면(예:
/// 카테고리 추가/수정)도 같은 하단 네비게이션 바를 보여주고, 탭을 누르면
/// BottomBarScreen 까지 그 탭으로 전환되게 하려고 상태를 여기서 공유한다.
class BottomNavState {
  BottomNavState._();

  static final ValueNotifier<int> index = ValueNotifier<int>(0);
}

class AppBottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const AppBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  static const _tabs = [
    ('assets/images/homebtn_none.png', '홈'),
    ('assets/images/focusbtn_none.png', '집중'),
    ('assets/images/ttbtn_none.png', '데일리로그'),
    ('assets/images/dailybtn_none.png', '일간'),
    ('assets/images/cumbtn_none.png', '누적'),
    ('assets/images/setbtn_none.png', '설정'),
  ];

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: currentIndex,
      onTap: onTap,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: const Color(0xFF4A90D9),
      unselectedItemColor: Colors.grey,
      items: _tabs.map((tab) {
        final (asset, label) = tab;
        return BottomNavigationBarItem(
          icon: Image.asset(
            asset,
            width: 28,
            height: 28,
            color: Colors.grey,
            colorBlendMode: BlendMode.srcIn,
          ),
          activeIcon: Image.asset(
            asset,
            width: 28,
            height: 28,
            color: const Color(0xFF4A90D9),
            colorBlendMode: BlendMode.srcIn,
          ),
          label: label,
        );
      }).toList(),
    );
  }
}
