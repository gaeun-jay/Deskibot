import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:deskibot/models/user_model.dart';
import 'package:deskibot/services/auth_service.dart';

class UserService {
  final _db = FirebaseFirestore.instance;

  Future<List<Category>> getCategories() async {
    final uid = await AuthService().getCurrentUid();
    if (uid == null) return [];
    final doc = await _db.collection('users').doc(uid).get();
    final data = doc.data();
    if (data == null) return [];
    final cats = data['settings']?['categories'] as List?;
    if (cats == null) return [];
    return cats
        .map((e) => Category.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
