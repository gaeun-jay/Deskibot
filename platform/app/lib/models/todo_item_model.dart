class TodoItem {
  final String id;
  final String content;      // Firestore: "content"
  final String date;         // "YYYY-MM-DD"
  final String? startTime;   // "HH:mm" — 시작 시각, null이면 시간 미정
  final String? endTime;     // "HH:mm" — 마감/종료 시각
  final bool notify;
  final int? notifyBefore;   // 몇 분 전 알림 (분)
  final bool isDone;         // Firestore: "is_done"
  final String? categoryId;
  final String color;        // hex ex) "#4A90D9" — 타임테이블 블록 색상

  static const String defaultColor = '#4A90D9';

  const TodoItem({
    required this.id,
    required this.content,
    required this.date,
    this.startTime,
    this.endTime,
    this.notify = false,
    this.notifyBefore,
    this.isDone = false,
    this.categoryId,
    this.color = defaultColor,
  });

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

  factory TodoItem.fromMap(String id, Map<String, dynamic> map) {
    // 구버전 호환: has_time + time → start_time
    final legacyTime = map['time'] as String?;
    final legacyHasTime = map['has_time'] as bool? ?? false;

    return TodoItem(
      id: id,
      content: map['content'] as String? ?? '',
      date: map['date'] as String? ?? '',
      startTime: map['start_time'] as String? ?? (legacyHasTime ? legacyTime : null),
      endTime: map['end_time'] as String? ?? map['deadline_time'] as String?,
      notify: map['notify'] as bool? ?? false,
      notifyBefore: map['notify_before'] as int?,
      isDone: map['is_done'] as bool? ?? false,
      categoryId: map['category_id'] as String?,
      color: map['color'] as String? ?? defaultColor,
    );
  }

  Map<String, dynamic> toMap() => {
        'content': content,
        'date': date,
        'start_time': startTime,
        'end_time': endTime,
        // start_time 있으면 deadline_time = end_time, 없으면 별도 마감 시각
        'deadline_time': endTime,
        'notify': notify,
        'notify_before': notifyBefore,
        'is_done': isDone,
        'category_id': categoryId,
        'color': color,
      };

  TodoItem copyWith({bool? isDone, String? content, String? color}) {
    return TodoItem(
      id: id,
      content: content ?? this.content,
      date: date,
      startTime: startTime,
      endTime: endTime,
      notify: notify,
      notifyBefore: notifyBefore,
      isDone: isDone ?? this.isDone,
      categoryId: categoryId,
      color: color ?? this.color,
    );
  }
}
