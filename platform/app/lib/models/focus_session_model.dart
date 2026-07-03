int _sumEventDurations(List? events) {
  if (events == null) return 0;
  return events.fold<int>(
    0,
    (sum, e) => sum + ((e as Map)['total_duration'] as int? ?? 0),
  );
}

// 이벤트 목록에서 가장 최신 start_time을 가진 이벤트의 (start_time, total_duration) 반환
({String time, int duration})? _latestEvent(List? events) {
  if (events == null || events.isEmpty) return null;
  final items = events
      .map((e) => e as Map)
      .where((e) => e['start_time'] != null)
      .toList();
  if (items.isEmpty) return null;
  items.sort((a, b) => (a['start_time'] as String).compareTo(b['start_time'] as String));
  final latest = items.last;
  return (
    time: latest['start_time'] as String,
    duration: latest['total_duration'] as int? ?? 0,
  );
}

class FocusSessionModel {
  final String id;
  final String type;
  final String date;
  final String endTime; // 어느 시간대에 속해있는지 확인하기 위한 데이터
  final int actualDuration;
  final int drowsyEventCount;
  final int drowsyDuration;
  final String? latestDrowsyTime;
  final int latestDrowsyDuration;
  final int phoneEventCount;
  final int phoneDuration;
  final String? latestPhoneTime;
  final int latestPhoneDuration;

  const FocusSessionModel({
    required this.id,
    required this.type,
    required this.date,
    required this.endTime,
    required this.actualDuration,
    required this.drowsyEventCount,
    required this.drowsyDuration,
    this.latestDrowsyTime,
    this.latestDrowsyDuration = 0,
    required this.phoneEventCount,
    required this.phoneDuration,
    this.latestPhoneTime,
    this.latestPhoneDuration = 0,
  });

  factory FocusSessionModel.fromMap(String id, Map<String, dynamic> map) {
    final drowsyEvents = map['drowsy_events'] as List?;
    final phoneEvents = map['phone_events'] as List?;
    return FocusSessionModel(
      id: id,
      type: map['type'] as String,
      date: map['date'] as String,
      endTime: map['end_time'] as String? ?? '00:00', // 어느 시간대에 속해있는지 확인하기 위한 데이터
      actualDuration: map['actual_duration'] as int? ?? 0,
      drowsyEventCount: drowsyEvents?.length ?? 0,
      drowsyDuration: _sumEventDurations(drowsyEvents),
      latestDrowsyTime: _latestEvent(drowsyEvents)?.time,
      latestDrowsyDuration: _latestEvent(drowsyEvents)?.duration ?? 0,
      phoneEventCount: phoneEvents?.length ?? 0,
      phoneDuration: _sumEventDurations(phoneEvents),
      latestPhoneTime: _latestEvent(phoneEvents)?.time,
      latestPhoneDuration: _latestEvent(phoneEvents)?.duration ?? 0,
    );
  }
}
