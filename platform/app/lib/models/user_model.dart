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
  final String id;
  final String name;
  final String color;

  Category({
    required this.id,
    required this.name,
    required this.color,
  });

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