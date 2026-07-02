import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:deskibot/models/daily_model.dart';
import 'package:deskibot/services/auth_service.dart';

class DailyService {
  final _db = FirebaseFirestore.instance;

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<Map<String, String>?> getTodayAnalysis() async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) return null;

    final today = _todayStr();
    final doc = await _db
        .collection('users')
        .doc(uid)
        .collection('analysis')
        .doc(today)
        .get();

    if (!doc.exists || doc.data() == null) return null;
    final data = doc.data()!;
    return {
      'title': data['title'] as String? ?? '',
      'subtitle': data['subtitle'] as String? ?? '',
      'advice': data['advice'] as String? ?? '',
    };
  }

  Future<DailyModel?> getTodayData() async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) return null;

    final today = _todayStr();
    final doc = await _db
        .collection('users')
        .doc(uid)
        .collection('stats')
        .doc('aggregations')
        .collection('daily')
        .doc(today)
        .get();

    if (!doc.exists || doc.data() == null) return null;
    return DailyModel.fromMap(today, doc.data()!);
  }
}
