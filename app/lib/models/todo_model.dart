/// 할 일. 체크리스트 형식으로만 표시하며 시작·종료 시각 개념이 없다.
/// 마감 시각(deadlineTime)만 선택적으로 갖는다.
class TodoModel {
  final String id;
  final String content;
  final String? categoryId;
  final String date;
  final bool notify;
  final String? deadlineTime;
  final int? notifyBefore;
  final bool isDone;

  const TodoModel({
    required this.id,
    required this.content,
    this.categoryId,
    required this.date,
    required this.notify,
    this.deadlineTime,
    this.notifyBefore,
    required this.isDone,
  });

  bool get hasDeadline => deadlineTime != null && deadlineTime!.isNotEmpty;

  factory TodoModel.fromMap(String id, Map<String, dynamic> map) {
    return TodoModel(
      id: id,
      content: map['content'] as String,
      categoryId: map['category_id'] as String?,
      date: map['date'] as String,
      notify: map['notify'] as bool? ?? false,
      deadlineTime: map['deadline_time'] as String?,
      notifyBefore: map['notify_before_min'] as int? ?? map['notify_before'] as int?,
      isDone: map['is_done'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'content': content,
        'category_id': categoryId,
        'date': date,
        'notify': notify,
        'deadline_time': deadlineTime,
        'notify_before_min': notifyBefore,
        'is_done': isDone,
      };

  TodoModel copyWith({bool? isDone, String? content}) {
    return TodoModel(
      id: id,
      content: content ?? this.content,
      categoryId: categoryId,
      date: date,
      notify: notify,
      deadlineTime: deadlineTime,
      notifyBefore: notifyBefore,
      isDone: isDone ?? this.isDone,
    );
  }
}
