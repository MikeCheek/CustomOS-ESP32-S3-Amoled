import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/battery_tracker.dart';
import '../services/watch_usage.dart';
import 'ble_provider.dart';

class UsageState {
  final WatchUsage? usage;
  final bool asking;

  /// The watch's battery from its status reports (every ~5 min while
  /// connected), kept for a week on the phone: (time, %, charging).
  final List<(DateTime, int, bool)> week;

  /// The energy log (usage part 5, firmware 3.5+): seconds per feature every 10 minutes.
  final EnergyLog? energy;

  /// The battery's capacity, to turn the gauge's % into mAh (Settings in the tracker).
  final int batteryMah;
  const UsageState({this.usage, this.asking = false, this.week = const [], this.energy, this.batteryMah = 1000});
  UsageState copyWith({WatchUsage? usage, bool? asking, List<(DateTime, int, bool)>? week, EnergyLog? energy, int? batteryMah}) =>
      UsageState(
        usage: usage ?? this.usage,
        asking: asking ?? this.asking,
        week: week ?? this.week,
        energy: energy ?? this.energy,
        batteryMah: batteryMah ?? this.batteryMah,
      );

  /// Where the battery went, feature by feature (null without enough log).
  TrackerReport? get tracker => energy == null ? null : analyseEnergy(energy!, capacityMah: batteryMah);
}

/// The Diagnostics' usage report: asks the watch ({"t":"usage"}), puts its
/// three parts together, and keeps a week of battery readings on the phone.
class UsageNotifier extends StateNotifier<UsageState> {
  static const _kWeek = 'usage_week';
  static const _kMah = 'battery_mah';
  final Ref _ref;
  final _parts = <int, Map<String, dynamic>>{};
  final _energy = <int, String>{}; // part 5 chunks by index
  UsageNotifier(this._ref) : super(const UsageState()) {
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final week = <(DateTime, int, bool)>[];
    for (final s in p.getStringList(_kWeek) ?? const <String>[]) {
      final f = s.split(',');
      if (f.length < 3) continue;
      final t = int.tryParse(f[0]), b = int.tryParse(f[1]);
      if (t != null && b != null) week.add((DateTime.fromMillisecondsSinceEpoch(t), b, f[2] == '1'));
    }
    if (mounted) state = state.copyWith(week: week, batteryMah: p.getInt(_kMah));
  }

  /// The battery's capacity in mAh, as printed on the cell.
  Future<void> setBatteryMah(int mah) async {
    if (mah < 50 || mah > 10000) return;
    state = state.copyWith(batteryMah: mah);
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kMah, mah);
  }

  Future<void> request() async {
    final ble = _ref.read(bleServiceProvider);
    if (!ble.hasPhoneLink) return;
    _parts.clear();
    _energy.clear();
    state = state.copyWith(asking: true);
    await ble.sendLink({'t': 'usage'});
    // older firmware never answers
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted && state.asking) state = state.copyWith(asking: false);
    });
  }

  void onPart(Map<String, dynamic> e) {
    final p = (e['p'] as num?)?.toInt();
    if (p == null) return;
    if (p == 5) {
      // the energy log comes in chunks of 10 slots
      final k = (e['k'] as num?)?.toInt(), n = (e['n'] as num?)?.toInt();
      final d = e['d'] as String?;
      if (k == null || n == null || d == null) return;
      _energy[k] = d;
      if (_energy.length >= n) {
        final log = EnergyLog.fromChunks(
          _energy,
          total: n,
          feats: (e['f'] as num?)?.toInt() ?? 14,
          iv: (e['iv'] as num?)?.toInt() ?? 10,
        );
        if (log != null) state = state.copyWith(energy: log);
      }
      return;
    }
    _parts[p] = e;
    final u = WatchUsage.fromParts(_parts, DateTime.now());
    if (u != null) state = state.copyWith(usage: u, asking: false);
  }

  /// A status report's battery: one point every 5 minutes at most, a week kept.
  Future<void> onReport(int battery, bool charging) async {
    if (battery < 0) return;
    final now = DateTime.now();
    final week = state.week;
    if (week.isNotEmpty && now.difference(week.last.$1) < const Duration(minutes: 4)) return;
    final cut = now.subtract(const Duration(days: 7));
    final next = [...week.where((w) => w.$1.isAfter(cut)), (now, battery, charging)];
    state = state.copyWith(week: next);
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kWeek, [for (final (t, b, c) in next) '${t.millisecondsSinceEpoch},$b,${c ? 1 : 0}']);
  }
}

final usageProvider = StateNotifierProvider<UsageNotifier, UsageState>((ref) => UsageNotifier(ref));
