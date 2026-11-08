/// The week in health, for Sunday's evening recap (evening_recap.dart): how
/// you slept, moved and trained over the last 7 days, against the 7 before.
/// Plain sentences, said on the watch; null without enough to say.
class HealthWeekInput {
  final List<(DateTime morning, int asleepMin)> nights;
  final List<(DateTime date, int steps, int exerciseMin)> days;
  final List<(DateTime start, Duration duration)> workouts;
  const HealthWeekInput({this.nights = const [], this.days = const [], this.workouts = const []});
}

String _hm(int min) => min >= 60 ? '${min ~/ 60} h ${(min % 60).toString().padLeft(2, '0')}' : '$min min';

String? weeklyHealth(DateTime now, HealthWeekInput w) {
  final today = DateTime(now.year, now.month, now.day);
  bool inWeek(DateTime d, int weeksAgo) {
    final day = DateTime(d.year, d.month, d.day);
    final from = today.subtract(Duration(days: 7 * (weeksAgo + 1) - 1)),
        to = today.subtract(Duration(days: 7 * weeksAgo));
    return !day.isBefore(from) && !day.isAfter(to);
  }

  double? avg(Iterable<int> xs) => xs.isEmpty ? null : xs.fold(0, (a, b) => a + b) / xs.length;
  final out = <String>[];

  // sleep
  final s0 = avg([
    for (final n in w.nights)
      if (inWeek(n.$1, 0) && n.$2 > 60) n.$2,
  ]);
  final s1 = avg([
    for (final n in w.nights)
      if (inWeek(n.$1, 1) && n.$2 > 60) n.$2,
  ]);
  if (s0 != null) {
    var t = 'This week you slept ${_hm(s0.round())} a night on average';
    if (s1 != null && (s0 - s1).abs() >= 10) {
      final d = (s0 - s1).abs().round();
      t += ', ${_hm(d)} ${s0 > s1 ? 'more' : 'less'} than the week before';
    }
    out.add('$t.');
  }

  // steps
  final st0 = avg([
    for (final d in w.days)
      if (inWeek(d.$1, 0) && d.$2 > 0) d.$2,
  ]);
  final st1 = avg([
    for (final d in w.days)
      if (inWeek(d.$1, 1) && d.$2 > 0) d.$2,
  ]);
  if (st0 != null) {
    var t = 'You walked ${(st0 / 100).round() * 100} steps a day';
    if (st1 != null && st1 > 0) {
      final pct = ((st0 - st1) / st1 * 100).round();
      if (pct.abs() >= 10) t += ', ${pct.abs()}% ${pct > 0 ? 'more' : 'fewer'} than the week before';
    }
    out.add('$t.');
  }

  // workouts
  final wo = [
    for (final x in w.workouts)
      if (inWeek(x.$1, 0)) x,
  ];
  if (wo.isNotEmpty) {
    final min = wo.fold(0, (a, x) => a + x.$2.inMinutes);
    out.add('${wo.length} workout${wo.length == 1 ? '' : 's'}, ${_hm(min)} in all.');
  } else if (s0 != null || st0 != null) {
    out.add('No workouts this week.');
  }
  return out.isEmpty ? null : out.join(' ');
}
