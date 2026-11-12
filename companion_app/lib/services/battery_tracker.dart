import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// The battery tracker: where the watch's charge goes, feature by feature.
///
/// The watch (firmware 3.5+) logs, every 10 minutes, how many seconds each
/// feature was on and the battery at the end of the slot (usage part 5).
/// The watch's PMU has no current sensor, so the phone works the currents
/// out: it starts from typical draws for this hardware and corrects them
/// against the battery gauge over every unplugged hour of the log (a
/// regularised non-negative least-squares fit). Features with enough
/// varied use get a measured current, the rest keep the typical one.

/// The features in the log, in the firmware's order (usage_stats.cpp EnergyFeat).
enum EnergyFeature { screen, bright, awakeOff, sleep, bleConn, bleAdv, wifi, gps, speaker, mic, aod, espnow, notif, wakes }

/// How a feature is shown and what it typically draws.
class FeatureInfo {
  final String label;

  /// Typical draw: mA for timed features, mAh per event for counts.
  final double typical;

  /// A count of events rather than seconds.
  final bool count;

  /// Something the person can switch off (for "hours gained if off").
  final bool optional;
  final EnergyGroup group;
  const FeatureInfo(this.label, this.typical, this.group, {this.count = false, this.optional = false});
}

/// Coarser groups for the hourly chart.
enum EnergyGroup { screen, standby, radio, gps, audio, aod, events }

const energyGroupLabels = {
  EnergyGroup.screen: 'Screen',
  EnergyGroup.standby: 'Standby',
  EnergyGroup.radio: 'Radios',
  EnergyGroup.gps: 'GPS',
  EnergyGroup.audio: 'Audio',
  EnergyGroup.aod: 'Always-on',
  EnergyGroup.events: 'Wake-ups',
};

/// Typical draws on the Waveshare 1.75" AMOLED (ESP32-S3, AXP2101), at the
/// battery. Screen: panel + CPU at low brightness; "bright" is what full
/// brightness adds on top. Standby awake = CPU idling at 80-160 MHz without
/// light sleep; asleep = automatic light sleep with BLE modem sleep.
const featureInfo = <EnergyFeature, FeatureInfo>{
  EnergyFeature.screen: FeatureInfo('Screen on', 32, EnergyGroup.screen),
  EnergyFeature.bright: FeatureInfo('Brightness', 40, EnergyGroup.screen),
  EnergyFeature.awakeOff: FeatureInfo('Screen off, awake', 24, EnergyGroup.standby),
  EnergyFeature.sleep: FeatureInfo('Screen off, asleep', 2.5, EnergyGroup.standby),
  EnergyFeature.bleConn: FeatureInfo('Bluetooth, connected', 2, EnergyGroup.radio),
  EnergyFeature.bleAdv: FeatureInfo('Bluetooth, searching', 1.2, EnergyGroup.radio),
  EnergyFeature.wifi: FeatureInfo('Wi-Fi', 60, EnergyGroup.radio, optional: true),
  EnergyFeature.gps: FeatureInfo('GPS', 25, EnergyGroup.gps, optional: true),
  EnergyFeature.speaker: FeatureInfo('Speaker', 55, EnergyGroup.audio),
  EnergyFeature.mic: FeatureInfo('Microphones', 14, EnergyGroup.audio, optional: true),
  EnergyFeature.aod: FeatureInfo('Always-on display', 7, EnergyGroup.aod, optional: true),
  EnergyFeature.espnow: FeatureInfo('ESP-NOW', 20, EnergyGroup.radio, optional: true),
  EnergyFeature.notif: FeatureInfo('Notifications', 0.03, EnergyGroup.events, count: true),
  EnergyFeature.wakes: FeatureInfo('Wake-ups', 0.01, EnergyGroup.events, count: true),
};

/// One 10-minute slot of the log.
class EnergySlot {
  /// Battery mV at the end of the slot (0 = empty).
  final int mv;

  /// Gauge % at the end, null when unknown.
  final int? pct;
  final int flags;

  /// Seconds (or counts) per feature, in [EnergyFeature] order.
  final List<int> s;
  const EnergySlot(this.mv, this.pct, this.flags, this.s);

  bool get plugged => flags & 1 != 0;
  bool get afterRestart => flags & 2 != 0;
  bool get empty => mv == 0;

  int v(EnergyFeature f) => f.index < s.length ? s[f.index] : 0;

  /// The slot's length in seconds: screen on + off awake + off asleep.
  int get seconds => v(EnergyFeature.screen) + v(EnergyFeature.awakeOff) + v(EnergyFeature.sleep);

  /// Hours for timed features, events for counts.
  double amount(EnergyFeature f) => featureInfo[f]!.count ? v(f).toDouble() : v(f) / 3600.0;
}

/// The watch's energy log, oldest slot first.
class EnergyLog {
  final List<EnergySlot> slots;
  final int intervalMin;

  /// When the phone received it (the last slot ended at most a slot before).
  final DateTime at;
  const EnergyLog(this.slots, this.intervalMin, this.at);

  static const _features = 14;

  /// Decodes the base64 chunks of part 5 (index k → "d"), all of them.
  static EnergyLog? fromChunks(Map<int, String> chunks, {required int total, int feats = _features, int iv = 10, DateTime? at}) {
    if (total <= 0 || chunks.length < total) return null;
    final size = 4 + 2 * feats;
    final slots = <EnergySlot>[];
    for (var k = 0; k < total; k++) {
      final d = chunks[k];
      if (d == null) return null;
      final Uint8List raw;
      try {
        raw = base64Decode(d);
      } on FormatException {
        return null;
      }
      final bd = ByteData.sublistView(raw);
      for (var o = 0; o + size <= raw.length; o += size) {
        final mv = bd.getUint16(o, Endian.little);
        final pct = raw[o + 2];
        final s = List<int>.generate(_features, (i) => i < feats ? bd.getUint16(o + 4 + 2 * i, Endian.little) : 0);
        if (mv == 0) continue; // nothing logged yet
        slots.add(EnergySlot(mv, pct > 100 ? null : pct, raw[o + 3], s));
      }
    }
    return slots.isEmpty ? null : EnergyLog(slots, iv, at ?? DateTime.now());
  }

  /// The end time of slot [i] (approximate across restarts).
  DateTime endOf(int i) => at.subtract(Duration(minutes: (slots.length - 1 - i) * intervalMin));
}

/// What one feature cost over the log's unplugged time.
class FeatureCost {
  final EnergyFeature feature;

  /// Hours on (or events) while unplugged.
  final double amount;

  /// Fitted draw: mA, or mAh per event.
  final double current;

  /// Its uncertainty (one standard deviation, same unit).
  final double sd;

  /// Fitted from the battery rather than the typical value.
  final bool measured;
  final double mah;

  /// Of all the battery used, 0..1.
  final double share;
  const FeatureCost(this.feature, this.amount, this.current, this.sd, this.measured, this.mah, this.share);

  FeatureInfo get info => featureInfo[feature]!;
}

/// One hour of the chart, newest last.
class TrackerHour {
  final DateTime end;
  final Map<EnergyGroup, double> mah;
  final bool plugged;

  /// The gauge's drop over the hour, % (null if unknown or charging).
  final int? drop;
  const TrackerHour(this.end, this.mah, this.plugged, this.drop);
  double get total => mah.values.fold(0.0, (a, b) => a + b);
}

class TrackerReport {
  final int capacityMah;
  final List<FeatureCost> costs; // most expensive first
  final double unpluggedHours;

  /// Modelled mAh over the unplugged time.
  final double totalMah;

  /// Over the stretches the gauge can be compared on: what it says and what the model says.
  final double gaugeMah, modelMah;

  /// Unplugged hour-long windows used for the fit.
  final int windows;
  final List<TrackerHour> hours;

  /// Hours of screen off asleep vs awake.
  final double sleepH, awakeOffH;

  const TrackerReport({
    required this.capacityMah,
    required this.costs,
    required this.unpluggedHours,
    required this.totalMah,
    required this.gaugeMah,
    required this.modelMah,
    required this.windows,
    required this.hours,
    required this.sleepH,
    required this.awakeOffH,
  });

  /// Average draw while unplugged.
  double get averageMa => unpluggedHours > 0 ? totalMah / unpluggedHours : 0;

  /// A full charge at this use, hours.
  double? get fullChargeHours => averageMa > 0.05 ? capacityMah / averageMa : null;

  /// Battery % a day at this use.
  double get percentPerDay => averageMa * 24 / capacityMah * 100;

  FeatureCost? cost(EnergyFeature f) {
    for (final c in costs) {
      if (c.feature == f) return c;
    }
    return null;
  }

  /// The share of screen-off time the chip spent in light sleep.
  double? get sleepShare => sleepH + awakeOffH > 0.1 ? sleepH / (sleepH + awakeOffH) : null;

  /// Draw with the screen off: standby plus what stays on in the background.
  double get screenOffMa {
    final h = sleepH + awakeOffH;
    if (h <= 0) return 0;
    var mah = 0.0;
    for (final c in costs) {
      if (c.feature == EnergyFeature.screen || c.feature == EnergyFeature.bright || c.info.count) continue;
      // background features are on screen-on and -off alike: count their screen-off part
      final offPart = c.feature == EnergyFeature.sleep || c.feature == EnergyFeature.awakeOff || c.feature == EnergyFeature.aod
          ? 1.0
          : h / math.max(h, unpluggedHours);
      mah += c.mah * offPart;
    }
    return mah / h;
  }

  /// Extra hours a charge would last without [f] (null when it's not optional or unused).
  double? hoursGainedWithout(EnergyFeature f) {
    final c = cost(f);
    final life = fullChargeHours;
    if (c == null || !c.info.optional || c.mah < 0.05 || life == null || unpluggedHours <= 0) return null;
    final rest = averageMa - c.mah / unpluggedHours;
    if (rest <= 0.05) return null;
    return capacityMah / rest - life;
  }

  /// The gauge fell more than the features explain (e.g. a feature the log doesn't know).
  double get unexplainedMah => gaugeMah - modelMah;
}

/// Fits the currents to the log and adds up what each feature cost.
/// [capacityMah] is the battery's capacity (the gauge's % turned into mAh).
TrackerReport? analyseEnergy(EnergyLog log, {int capacityMah = 1000, int windowSlots = 6}) {
  final feats = EnergyFeature.values;
  final n = feats.length;
  final sl = log.slots;
  final cap = capacityMah.toDouble();

  // ---- the windows: runs of unplugged slots between two gauge readings
  final xs = <List<double>>[];
  final ys = <double>[];
  final modelSet = <int>{}; // slots inside a window
  var gaugeMah = 0.0;
  var start = -1; // slot whose end reading opens the window
  for (var i = 0; i < sl.length; i++) {
    final s = sl[i];
    final usable = !s.plugged && !s.afterRestart && s.pct != null;
    if (!usable) {
      start = s.pct != null && !s.plugged ? i : -1;
      continue;
    }
    if (start < 0) {
      start = i;
      continue;
    }
    if (i - start >= windowSlots) {
      final x = List<double>.filled(n, 0);
      for (var j = start + 1; j <= i; j++) {
        for (final f in feats) {
          x[f.index] += sl[j].amount(f);
        }
        modelSet.add(j);
      }
      final y = (sl[start].pct! - s.pct!) * cap / 100;
      xs.add(x);
      ys.add(y);
      gaugeMah += y;
      start = i;
    }
  }

  // ---- the fit: MAP with a prior at the typical draws, currents >= 0
  final i0 = [for (final f in feats) featureInfo[f]!.typical];
  final sf = [for (final f in feats) featureInfo[f]!.typical * 0.7]; // prior spread
  final sy = 0.006 * cap; // gauge noise per window: two 1% readings, rounded
  final a = List.generate(n, (_) => List<double>.filled(n, 0));
  final b = List<double>.filled(n, 0);
  for (var w = 0; w < xs.length; w++) {
    final x = xs[w];
    for (var p = 0; p < n; p++) {
      if (x[p] == 0) continue;
      b[p] += x[p] * ys[w] / (sy * sy);
      for (var q = 0; q < n; q++) {
        a[p][q] += x[p] * x[q] / (sy * sy);
      }
    }
  }
  for (var p = 0; p < n; p++) {
    a[p][p] += 1 / (sf[p] * sf[p]);
    b[p] += i0[p] / (sf[p] * sf[p]);
  }
  final cur = [...i0];
  for (var it = 0; it < 400; it++) {
    var moved = 0.0;
    for (var p = 0; p < n; p++) {
      var r = b[p];
      for (var q = 0; q < n; q++) {
        if (q != p) r -= a[p][q] * cur[q];
      }
      final v = math.max(0.0, r / a[p][p]);
      moved = math.max(moved, (v - cur[p]).abs() / math.max(1e-3, i0[p]));
      cur[p] = v;
    }
    if (moved < 1e-6) break;
  }
  final inv = _invert(a);
  final sd = [for (var p = 0; p < n; p++) inv == null ? sf[p] : math.sqrt(math.max(0, inv[p][p]))];

  // ---- what each feature cost while unplugged
  final amount = List<double>.filled(n, 0);
  var unplugH = 0.0, modelMah = 0.0;
  for (var i = 0; i < sl.length; i++) {
    final s = sl[i];
    if (s.plugged) continue;
    unplugH += s.seconds / 3600;
    for (final f in feats) {
      final x = s.amount(f);
      amount[f.index] += x;
      if (modelSet.contains(i)) modelMah += x * cur[f.index];
    }
  }
  if (unplugH < 0.25) return null;
  final mah = [for (var p = 0; p < n; p++) amount[p] * cur[p]];
  final total = mah.fold(0.0, (x, y) => x + y);
  final costs = [
    for (final f in feats)
      FeatureCost(
        f,
        amount[f.index],
        cur[f.index],
        sd[f.index],
        sd[f.index] < 0.5 * sf[f.index],
        mah[f.index],
        total > 0 ? mah[f.index] / total : 0,
      ),
  ]..sort((x, y) => y.mah.compareTo(x.mah));

  // ---- by the hour, newest last
  final hours = <TrackerHour>[];
  final perHour = math.max(1, 60 ~/ log.intervalMin);
  for (var end = sl.length; end > 0 && hours.length < 24; end -= perHour) {
    final from = math.max(0, end - perHour);
    final g = {for (final e in EnergyGroup.values) e: 0.0};
    var plugged = false;
    for (var i = from; i < end; i++) {
      if (sl[i].plugged) {
        plugged = true;
        continue;
      }
      for (final f in feats) {
        g[featureInfo[f]!.group] = g[featureInfo[f]!.group]! + sl[i].amount(f) * cur[f.index];
      }
    }
    int? drop;
    if (!plugged && from > 0) {
      final p0 = sl[from - 1].pct, p1 = sl[end - 1].pct;
      if (p0 != null && p1 != null && !sl[from - 1].plugged) drop = p0 - p1;
    }
    hours.insert(0, TrackerHour(log.endOf(end - 1), g, plugged, drop));
  }

  return TrackerReport(
    capacityMah: capacityMah,
    costs: costs,
    unpluggedHours: unplugH,
    totalMah: total,
    gaugeMah: gaugeMah,
    modelMah: modelMah,
    windows: xs.length,
    hours: hours,
    sleepH: amount[EnergyFeature.sleep.index],
    awakeOffH: amount[EnergyFeature.awakeOff.index],
  );
}

/// Plain-language notes from the tracker.
List<(bool warn, String title, String detail)> trackerFindings(TrackerReport r) {
  final out = <(bool, String, String)>[];
  String h(double x) => x >= 1 ? '${x.toStringAsFixed(1)} h' : '${(x * 60).round()} min';
  final top = r.costs.where((c) => c.mah > 0.5).take(1).toList();
  if (top.isNotEmpty) {
    final c = top.first;
    out.add((
      false,
      '${c.info.label} used the most',
      '${(c.share * 100).round()}% of the battery used (${c.mah.toStringAsFixed(0)} mAh over ${h(r.unpluggedHours)} unplugged)',
    ));
  }
  final aw = r.cost(EnergyFeature.awakeOff);
  final share = r.sleepShare;
  if (aw != null && share != null && share < 0.7 && r.awakeOffH > 1) {
    out.add((
      true,
      'Stayed awake ${h(r.awakeOffH)} with the screen off',
      'That cost about ${aw.mah.toStringAsFixed(0)} mAh. In light sleep it would have been '
          '${(r.awakeOffH * (r.cost(EnergyFeature.sleep)?.current ?? 2.5)).toStringAsFixed(0)} mAh - see what kept it awake below.',
    ));
  }
  final mic = r.cost(EnergyFeature.mic);
  if (mic != null && mic.amount > 2) {
    out.add((true, 'The microphones were on ${h(mic.amount)}', 'The wake word listens all the time; ${mic.mah.toStringAsFixed(0)} mAh.'));
  }
  if (r.windows >= 3 && r.gaugeMah > 20 && r.unexplainedMah > 0.25 * r.gaugeMah) {
    out.add((
      true,
      'Drain the features don\'t explain',
      'The gauge fell ${r.gaugeMah.toStringAsFixed(0)} mAh where the features add up to ${r.modelMah.toStringAsFixed(0)} mAh. '
          'Check the battery capacity setting, or something is drawing current the log can\'t see.',
    ));
  }
  return out;
}

/// Gauss-Jordan inverse of a small symmetric positive matrix (null if singular).
List<List<double>>? _invert(List<List<double>> m) {
  final n = m.length;
  final a = [for (final r in m) [...r, ...List<double>.filled(n, 0)]];
  for (var i = 0; i < n; i++) {
    a[i][n + i] = 1;
  }
  for (var c = 0; c < n; c++) {
    var piv = c;
    for (var r = c + 1; r < n; r++) {
      if (a[r][c].abs() > a[piv][c].abs()) piv = r;
    }
    if (a[piv][c].abs() < 1e-12) return null;
    final t = a[c];
    a[c] = a[piv];
    a[piv] = t;
    final d = a[c][c];
    for (var k = 0; k < 2 * n; k++) {
      a[c][k] /= d;
    }
    for (var r = 0; r < n; r++) {
      if (r == c || a[r][c] == 0) continue;
      final f = a[r][c];
      for (var k = 0; k < 2 * n; k++) {
        a[r][k] -= f * a[c][k];
      }
    }
  }
  return [for (final r in a) r.sublist(n)];
}
