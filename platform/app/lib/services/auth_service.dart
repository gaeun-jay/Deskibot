import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:deskibot/models/user_model.dart';

class AuthService {
  final _db = FirebaseFirestore.instance;
  final _uuid = const Uuid();

  // 비밀번호 해싱
  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    return sha256.convert(bytes).toString();
  }

  // 회원가입
  Future<void> signUp({
    required String name,
    required String userType,
    required String loginId,
    required String password,
  }) async {
    // 아이디 중복 확인
    final query = await _db
        .collection('users')
        .where('auth.id', isEqualTo: loginId)
        .limit(1)
        .get();

    if (query.docs.isNotEmpty) {
      throw Exception('이미 사용 중인 아이디예요');
    }

    final uid = _uuid.v4();

    final user = UserModel(
      uid: uid,
      name: name,
      userType: userType,
      auth: Auth(
        id: loginId,
        password: _hashPassword(password),
      ),
      categories: [
        Category(id: 'cat_01', name: '공부', color: '#4472C4'),
        Category(id: 'cat_02', name: '업무', color: '#ED7D31'),
        Category(id: 'cat_03', name: '운동', color: '#70AD47'),
      ],
    );

    // Firestore에 저장
    await _db.collection('users').doc(uid).set(user.toMap());

    // 로컬에 사용자 정보 저장
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('uid', uid);
    await prefs.setString('login_id', loginId);
    await prefs.setString('password', user.auth.password);
    await prefs.setString('name', name);
  }

  // 로그인
  Future<void> login({
    required String loginId,
    required String password,
  }) async {
    final hashedPassword = _hashPassword(password);
    final query = await _db
        .collection('users')
        .where('auth.id', isEqualTo: loginId)
        .where('auth.password', isEqualTo: hashedPassword)
        .limit(1)
        .get();

    if (query.docs.isEmpty) {
      throw Exception('아이디 또는 비밀번호를 확인해주세요');
    }

    // 로컬에 사용자 정보 저장
    final doc = query.docs.first;
    final uid = doc.id;
    final name = doc.data()['name'] as String;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('uid', uid);
    await prefs.setString('login_id', loginId);
    await prefs.setString('password', hashedPassword);
    await prefs.setString('name', name);
  }

  // 자동 로그인 확인
  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = prefs.getString('uid');
    final loginId = prefs.getString('login_id');
    final password = prefs.getString('password');
    return uid != null && loginId != null && password != null;
  }

  // 로그아웃
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('uid');
    await prefs.remove('login_id');
    await prefs.remove('password');
    await prefs.remove('name');
  }

  // 현재 uid 가져오기
  Future<String?> getCurrentUid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('uid');
  }

  // 현재 사용자 이름 가져오기
  Future<String?> getCurrentName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('name');
  }
}