class TodoModel {
  final String id;
  final String content;
  final String? categoryId;
  final String date;
  final String? startTime;
  final String? endTime;
  final bool notify;
  final String? deadlineTime;
  final int? notifyBefore;
  final bool isDone;

  bool get hasTime => startTime != null;

  int get startMinutes => startTime != null ? _toMinutes(startTime!) : -1;

  int get endMinutes {
    if (startTime == null) return -1;
    if (endTime != null) return _toMinutes(endTime!);
    return _toMinutes(startTime!) + 30;
  }

  static int _toMinutes(String t) {
    final parts = t.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  const TodoModel({
    required this.id,
    required this.content,
    this.categoryId,
    required this.date,
    this.startTime,
    this.endTime,
    required this.notify,
    this.deadlineTime,
    this.notifyBefore,
    required this.isDone,
  });

  factory TodoModel.fromMap(String id, Map<String, dynamic> map) {
    // 구버전 호환: has_time + time → start_time
    final legacyTime = map['time'] as String?;
    final legacyHasTime = map['has_time'] as bool? ?? false;

    return TodoModel(
      id: id,
      content: map['content'] as String,
      categoryId: map['category_id'] as String?,
      date: map['date'] as String,
      startTime: map['start_time'] as String? ?? (legacyHasTime ? legacyTime : null),
      endTime: map['end_time'] as String? ?? map['deadline_time'] as String?,
      notify: map['notify'] as bool? ?? false,
      deadlineTime: map['deadline_time'] as String?,
      notifyBefore: map['notify_before'] as int?,
      isDone: map['is_done'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'content': content,
        'category_id': categoryId,
        'date': date,
        'start_time': startTime,
        'end_time': endTime,
        'notify': notify,
        'deadline_time': deadlineTime,
        'notify_before': notifyBefore,
        'is_done': isDone,
      };

  TodoModel copyWith({bool? isDone, String? content}) {
    return TodoModel(
      id: id,
      content: content ?? this.content,
      categoryId: categoryId,
      date: date,
      startTime: startTime,
      endTime: endTime,
      notify: notify,
      deadlineTime: deadlineTime,
      notifyBefore: notifyBefore,
      isDone: isDone ?? this.isDone,
    );
  }
}
