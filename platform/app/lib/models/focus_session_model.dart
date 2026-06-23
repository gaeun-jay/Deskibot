int _sumEventDurations(List? events) {
  if (events == null) return 0;
  return events.fold<int>(
    0,
    (sum, e) => sum + ((e as Map)['total_duration'] as int? ?? 0),
  );
}

class FocusSessionModel {
  final String id;
  final String type;
  final String date;
  final int actualDuration;
  final int drowsyEventCount;
  final int drowsyDuration;
  final int phoneEventCount;
  final int phoneDuration;

  const FocusSessionModel({
    required this.id,
    required this.type,
    required this.date,
    required this.actualDuration,
    required this.drowsyEventCount,
    required this.drowsyDuration,
    required this.phoneEventCount,
    required this.phoneDuration,
  });

  factory FocusSessionModel.fromMap(String id, Map<String, dynamic> map) {
    final drowsyEvents = map['drowsy_events'] as List?;
    final phoneEvents = map['phone_events'] as List?;
    return FocusSessionModel(
      id: id,
      type: map['type'] as String,
      date: map['date'] as String,
      actualDuration: map['actual_duration'] as int? ?? 0,
      drowsyEventCount: drowsyEvents?.length ?? 0,
      drowsyDuration: _sumEventDurations(drowsyEvents),
      phoneEventCount: phoneEvents?.length ?? 0,
      phoneDuration: _sumEventDurations(phoneEvents),
    );
  }
}
