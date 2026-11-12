import 'package:flutter_test/flutter_test.dart';
import 'package:amoled_companion/services/weekly_health.dart';

void main() {
  final sunday = DateTime(2026, 11, 8, 20, 30);
  DateTime ago(int d) => DateTime(2026, 11, 8).subtract(Duration(days: d));

  test('the week against the one before', () {
    final s = weeklyHealth(
      sunday,
      HealthWeekInput(
        nights: [for (var d = 0; d < 7; d++) (ago(d), 450), for (var d = 7; d < 14; d++) (ago(d), 410)],
        days: [for (var d = 0; d < 7; d++) (ago(d), 6000, 20), for (var d = 7; d < 14; d++) (ago(d), 8000, 30)],
        workouts: [
          (ago(2), const Duration(minutes: 40)),
          (ago(5), const Duration(minutes: 35)),
          (ago(9), const Duration(hours: 1)),
        ],
      ),
    );
    expect(
      s,
      'This week you slept 7 h 30 a night on average, 40 min more than the week before. '
      'You walked 6000 steps a day, 25% fewer than the week before. 2 workouts, 1 h 15 in all.',
    );
  });

  test('nothing to compare with, and nothing at all', () {
    expect(
      weeklyHealth(sunday, HealthWeekInput(nights: [(ago(1), 420)])),
      'This week you slept 7 h 00 a night on average. No workouts this week.',
    );
    expect(weeklyHealth(sunday, const HealthWeekInput()), isNull);
  });
}
