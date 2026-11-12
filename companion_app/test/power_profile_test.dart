import 'package:flutter_test/flutter_test.dart';
import 'package:amoled_companion/services/watch_usage.dart';

void main() {
  test('parses the watch\'s part 5', () {
    final p = PowerProfile.fromJson({
      'v': 1,
      'off': {
        't': 7200,
        'slp': 20,
        'cpu': {'loop': 15, 'motion': 40, 'bt': 8},
        'lk': [
          ['i2s', 975],
          ['awake', 0],
        ],
      },
      'on': {
        't': 180,
        'slp': 0,
        'cpu': {'display': 300},
      },
    })!;
    expect(p.off!.seconds, 7200);
    expect(p.off!.asleep, closeTo(0.02, 1e-9));
    expect(p.off!.locks.first, ('i2s', 975));
    expect(p.on!.cpu['display'], 300);
    expect(PowerProfile.fromJson(null), isNull);
    expect(PowerProfile.fromJson({'v': 1}), isNull);
  });

  test('kept awake by I2S: awake-idle tops the breakdown, named after the lock', () {
    final w = ProfileWindow(7200, 20, {'loop': 15, 'motion': 40}, [('i2s', 975)]);
    final rows = PowerProfile.breakdown(w, measuredMa: 45);
    expect(rows.first.label, 'Awake, doing nothing');
    expect(rows.first.detail, contains('sound (I2S audio clock)'));
    expect(rows.fold(0.0, (a, r) => a + r.mA!), closeTo(45, 0.5));
    expect(rows.fold(0.0, (a, r) => a + r.share), closeTo(1, 0.01));
  });

  test('mostly asleep: sleep and the busiest feature lead', () {
    final w = ProfileWindow(7200, 960, {'motion': 30, 'bt': 5}, const []);
    final rows = PowerProfile.breakdown(w);
    expect(rows.map((r) => r.label).take(2), containsAll(['Asleep', 'Motion sensing']));
    expect(rows.every((r) => r.mA == null), isTrue); // no measured drain: shares only
  });

  test('a usage report carries the profile', () {
    final u = WatchUsage.fromParts({
      0: {'bat': '6464', 'chg': '00', 'iv': 10},
      1: {'on': List.filled(24, 0), 'wk': List.filled(24, 0), 'ony': List.filled(24, 0)},
      2: {'apps': []},
      5: {
        'pf': {
          'v': 1,
          'off': {'t': 3600, 'slp': 500, 'cpu': {}, 'lk': []},
        },
      },
    }, DateTime(2026, 11, 12, 12));
    expect(u!.profile!.off!.sleepPermille, 500);
    expect(u.profile!.on, isNull);
  });

  test('a long screen-off spell mostly awake is reported, with the lock', () {
    final u = WatchUsage(
      battery: const [],
      charging: const [],
      intervalMin: 10,
      at: DateTime(2026, 11, 12, 12),
      onToday: List.filled(24, 0),
      wakesToday: List.filled(24, 0),
      onYesterday: List.filled(24, 0),
      apps: const [],
      profile: PowerProfile(ProfileWindow(7200, 30, const {}, [('i2s', 960)]), null),
    );
    final f = usageFindings(u);
    expect(f.any((x) => x.title.startsWith('Asleep only 3%') && x.detail.contains('I2S')), isTrue);
  });
}
