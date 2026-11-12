import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:amoled_companion/services/battery_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Packs slots the way the firmware does: 32 bytes little-endian each.
String _pack(List<(int mv, int pct, int flags, List<int> s)> slots) {
  final b = ByteData(slots.length * 32);
  for (var i = 0; i < slots.length; i++) {
    final (mv, pct, flags, s) = slots[i];
    final o = i * 32;
    b.setUint16(o, mv, Endian.little);
    b.setUint8(o + 2, pct);
    b.setUint8(o + 3, flags);
    for (var f = 0; f < 14; f++) {
      b.setUint16(o + 4 + 2 * f, f < s.length ? s[f] : 0, Endian.little);
    }
  }
  return base64Encode(b.buffer.asUint8List());
}

/// A day of slots: the phone away (Bluetooth searching), a few glances an
/// hour, and ten hours where the chip stayed awake with the screen off.
/// The battery follows [awakeMa] for that awake time, typical draws otherwise.
List<(int, int, int, List<int>)> _day({double awakeMa = 45, bool wifiOn = false}) {
  final rnd = math.Random(7);
  final out = <(int, int, int, List<int>)>[];
  var level = 100.0;
  for (var i = 0; i < 144; i++) {
    final on = i > 40 && i < 130 ? [0, 0, 0, 30, 120, 300][rnd.nextInt(6)] : 0;
    final awake = i > 44 && i < 106 ? 600 - on : 0;
    final s = List<int>.filled(14, 0);
    s[EnergyFeature.screen.index] = on;
    s[EnergyFeature.bright.index] = on ~/ 2;
    s[EnergyFeature.awakeOff.index] = awake;
    s[EnergyFeature.sleep.index] = 600 - on - awake;
    s[EnergyFeature.bleAdv.index] = 600;
    if (wifiOn && i < 48) s[EnergyFeature.wifi.index] = 600; // the first 8 hours
    s[EnergyFeature.wakes.index] = on > 0 ? 1 : 0;
    var mah = 0.0;
    for (final f in EnergyFeature.values) {
      final info = featureInfo[f]!;
      final cur = f == EnergyFeature.awakeOff ? awakeMa : info.typical;
      mah += info.count ? s[f.index] * cur : s[f.index] / 3600 * cur;
    }
    level -= mah / 1000 * 100;
    out.add((3700 + level.round() * 5, level.round().clamp(0, 100), i == 0 ? 2 : 0, s));
  }
  return out;
}

EnergyLog _log(List<(int, int, int, List<int>)> slots) {
  final chunks = <int, String>{};
  for (var k = 0; k * 10 < slots.length; k++) {
    chunks[k] = _pack(slots.sublist(k * 10, math.min(slots.length, k * 10 + 10)));
  }
  return EnergyLog.fromChunks(chunks, total: chunks.length, at: DateTime(2026, 11, 12, 23))!;
}

void main() {
  test('decodes the firmware slots', () {
    final s = List<int>.generate(14, (i) => i * 3);
    final log = EnergyLog.fromChunks(
      {0: _pack([(0, 255, 0, List.filled(14, 0)), (3987, 81, 3, s)])},
      total: 1,
    )!;
    expect(log.slots.length, 1); // the empty slot is skipped
    final x = log.slots.single;
    expect(x.mv, 3987);
    expect(x.pct, 81);
    expect(x.plugged, isTrue);
    expect(x.afterRestart, isTrue);
    expect(x.v(EnergyFeature.wifi), 18);
    expect(x.seconds, 0 + 6 + 9);
  });

  test('waits for every chunk', () {
    expect(EnergyLog.fromChunks({0: _pack(_day().sublist(0, 10))}, total: 2), isNull);
  });

  test('measures a standby current far from the typical one', () {
    final r = analyseEnergy(_log(_day(awakeMa: 45)))!;
    final aw = r.cost(EnergyFeature.awakeOff)!;
    expect(aw.measured, isTrue);
    expect(aw.current, closeTo(45, 8));
    expect(r.windows, greaterThan(15));
    expect(r.unpluggedHours, closeTo(24, 0.5));
    // the model explains the gauge
    expect(r.modelMah, closeTo(r.gaugeMah, r.gaugeMah * 0.15));
    expect(r.sleepShare, lessThan(0.85));
  });

  test('charging time is left out', () {
    final day = _day();
    final plugged = [
      for (var i = 0; i < day.length; i++)
        i < 72 ? (day[i].$1, day[i].$2, day[i].$3 | 1, day[i].$4) : day[i],
    ];
    final r = analyseEnergy(_log(plugged))!;
    expect(r.unpluggedHours, closeTo(12, 0.5));
    expect(r.hours.where((h) => h.plugged).length, greaterThanOrEqualTo(11));
  });

  test('switching Wi-Fi off gives hours back', () {
    final r = analyseEnergy(_log(_day(wifiOn: true)))!;
    final w = r.cost(EnergyFeature.wifi)!;
    expect(w.mah, greaterThan(350));
    expect(r.costs.first.feature, EnergyFeature.wifi);
    expect(r.hoursGainedWithout(EnergyFeature.wifi), greaterThan(10));
    expect(r.hoursGainedWithout(EnergyFeature.screen), isNull); // not optional
  });

  test('notes the awake standby', () {
    final r = analyseEnergy(_log(_day(awakeMa: 45)))!;
    expect(trackerFindings(r).any((n) => n.$2.startsWith('Stayed awake')), isTrue);
  });
}
