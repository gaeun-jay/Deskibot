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
    return TodoModel(
      id: id,
      content: map['content'] as String,
      categoryId: map['category_id'] as String?,
      date: map['date'] as String,
      startTime: map['start_time'] as String?,
      endTime: map['end_time'] as String?,
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
<<<<<<< HEAD
}
=======
}
>>>>>>> origin/app-develop
