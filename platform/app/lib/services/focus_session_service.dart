import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:deskibot/models/focus_session_model.dart';
import 'package:deskibot/services/auth_service.dart';

class FocusSessionService {
  final _db = FirebaseFirestore.instance;

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Stream<List<FocusSessionModel>> getTodaySessions() {
    final today = _todayStr();
    return Stream.fromFuture(AuthService().getCurrentUid()).asyncExpand((uid) {
      if (uid == null) return Stream.value([]);
      return _db
          .collection('users')
          .doc(uid)
          .collection('focus_sessions')
          .where('date', isEqualTo: today)
          .snapshots()
          .map((snap) => snap.docs
              .map((doc) => FocusSessionModel.fromMap(doc.id, doc.data()))
              .toList());
    });
  }
}
