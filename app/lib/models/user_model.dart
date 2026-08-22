class UserModel {
  final String uid;
  final String name;
  final String userType;
  final Auth auth;
  final List<Category> categories;

  UserModel({
    required this.uid,
    required this.name,
    required this.userType,
    required this.auth,
    required this.categories,
  });

  factory UserModel.fromMap(Map<String, dynamic> map) {
    return UserModel(
      uid: map['uid'],
      name: map['name'],
      userType: map['settings']['user_type'],
      auth: Auth.fromMap(map['auth']),
      categories: (map['settings']['categories'] as List)
          .map((e) => Category.fromMap(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  Map<String, dynamic> toMap() => {
    'uid': uid,
    'name': name,
    'auth': auth.toMap(),
    'settings': {
      'user_type': userType,
      'categories': categories.map((e) => e.toMap()).toList(),
    },
  };
}

class Auth {
  final String id;
  final String password; // 해싱 처리됨

  Auth({
    required this.id,
    required this.password,
  });

  factory Auth.fromMap(Map<String, dynamic> map) {
    return Auth(
      id: map['id'],
      password: map['password'],
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'password': password,
  };
}

class Category {
  /// 가입할 때 서버가 만들어주는 기본 카테고리 중 사용자가 손대지 못하는 이름.
  /// server/sw/app/auth_service.py 의 DEFAULT_CATEGORIES 와 맞춰야 한다.
  static const lockedNames = {'기타'};

  final String id;
  final String name;
  final String color;

  Category({
    required this.id,
    required this.name,
    required this.color,
  });

  /// 설정 화면에서 수정·삭제를 막을 카테고리인지.
  ///
  /// "기타"는 어디에도 안 맞는 할 일을 받는 자리다. 이름이 바뀌거나 사라지면
  /// 그 자리가 없어지므로 잠가둔다. 서버에는 같은 제약이 없으니 API 를 직접
  /// 부르면 바꿀 수 있다 — 화면에서의 실수를 막는 것이 목적이다.
  bool get isLocked => lockedNames.contains(name);

  factory Category.fromMap(Map<String, dynamic> map) {
    return Category(
      id: map['id'],
      name: map['name'],
      color: map['color'],
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'color': color,
  };
}