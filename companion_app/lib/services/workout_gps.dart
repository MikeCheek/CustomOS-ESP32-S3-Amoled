import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';

/// Distance for an outdoor workout on a watch without GPS, from the phone's.
///
/// The watch asks with {"e":"wogps","on":1,"st":<workout start>} (again after
/// a reconnect) and ends it with "on":0. Fixes come from the GPS one a second
/// (PhoneBridge.kt, com.amoledwatch.native/location); every 5 s the running
/// total goes back as {"t":"wopos","st":..,"m":<meters>}, or "err" with why
/// there's none. The watch adds the increases, leaving its paused stretches out.
class WorkoutGps {
  WorkoutGps._();
  static final instance = WorkoutGps._();

  static const _fixes = EventChannel('com.amoledwatch.native/location');

  Future<void> Function(Map<String, dynamic>)? _send;
  StreamSubscription? _sub;
  Timer? _tick, _orphan;
  int _st = 0;
  double _m = 0;
  double? _lat, _lon;
  int _lastT = 0;
  String? _err;

  bool get running => _sub != null;

  /// [send] delivers to the watch (throws or does nothing when it's away).
  void start(int st, Future<void> Function(Map<String, dynamic>) send) {
    _send = send;
    _orphan?.cancel();
    _orphan = null;
    if (running && st == _st) {
      _report(); // the same workout, after a reconnect: carry on
      return;
    }
    stop();
    _st = st;
    _m = 0;
    _lat = _lon = null;
    _err = null;
    _sub = _fixes.receiveBroadcastStream().listen(_onFix, onError: (Object e) {
      _err = e is PlatformException ? (e.message ?? e.code) : '$e';
      _report();
    });
    _tick = Timer.periodic(const Duration(seconds: 5), (_) => _report());
  }

  /// Error text for the watch when tracking can't start at all.
  void refuse(int st, String why, Future<void> Function(Map<String, dynamic>) send) {
    unawaited(send({'t': 'wopos', 'st': st, 'err': why}).catchError((_) {}));
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _tick?.cancel();
    _tick = null;
    _orphan?.cancel();
    _orphan = null;
  }

  /// The watch went away: keep tracking (it's probably still on the wrist,
  /// the walk goes on), but not forever if the workout ended meanwhile.
  void linkLost() {
    if (!running) return;
    _orphan?.cancel();
    _orphan = Timer(const Duration(minutes: 30), stop);
  }

  void _onFix(dynamic ev) {
    final m = Map<String, dynamic>.from(ev as Map);
    final lat = (m['lat'] as num).toDouble(), lon = (m['lon'] as num).toDouble();
    final acc = (m['acc'] as num?)?.toDouble() ?? 999;
    final t = (m['t'] as num?)?.toInt() ?? 0;
    _err = null;
    if (acc > 25) return; // too rough to measure a walk with
    final pLat = _lat, pLon = _lon;
    if (pLat == null || pLon == null) {
      _lat = lat;
      _lon = lon;
      _lastT = t;
      return;
    }
    final d = _haversine(pLat, pLon, lat, lon);
    final dt = max(1, (t - _lastT) ~/ 1000);
    if (d < max(3.0, acc / 2)) return; // standing still: GPS jitter, not distance
    if (d / dt < 15) _m += d; // faster than 15 m/s on foot or a bike: a jump, not a move
    _lat = lat;
    _lon = lon;
    _lastT = t;
  }

  void _report() {
    final send = _send;
    if (send == null) return;
    final msg = <String, dynamic>{'t': 'wopos', 'st': _st, 'm': _m.round()};
    if (_err != null) msg['err'] = _err;
    unawaited(send(msg).catchError((_) {}));
  }

  static double _haversine(double la1, double lo1, double la2, double lo2) {
    const r = 6371000.0, d = pi / 180;
    final dla = (la2 - la1) * d, dlo = (lo2 - lo1) * d;
    final a = sin(dla / 2) * sin(dla / 2) + cos(la1 * d) * cos(la2 * d) * sin(dlo / 2) * sin(dlo / 2);
    return 2 * r * atan2(sqrt(a), sqrt(1 - a));
  }
}
