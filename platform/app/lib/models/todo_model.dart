class TodoModel {
  final String id;
  final String content;
  final String? categoryId;
  final String date;
  final String? time;
  final bool hasTime;
  final bool notify;
  final String? deadlineTime;
  final int? notifyBefore;
  final bool isDone;

  const TodoModel({
    required this.id,
    required this.content,
    this.categoryId,
    required this.date,
    this.time,
    required this.hasTime,
    required this.notify,
    this.deadlineTime,
    this.notifyBefore,
    required this.isDone,
  });

  factory TodoModel.fromMap(String id, Map<String, dynamic> map) {
    return TodoModel(
      id: id,
      content: map['content'] as String,
      categoryId: map['category_id'] as String?,
      date: map['date'] as String,
      time: map['time'] as String?,
      hasTime: map['has_time'] as bool? ?? false,
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
        'time': time,
        'has_time': hasTime,
        'notify': notify,
        'deadline_time': deadlineTime,
        'notify_before': notifyBefore,
        'is_done': isDone,
      };
}
