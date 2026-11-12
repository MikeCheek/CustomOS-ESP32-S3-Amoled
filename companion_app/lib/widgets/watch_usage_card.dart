import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/ble_provider.dart';
import '../providers/companion_provider.dart';
import '../providers/update_provider.dart';
import '../providers/usage_provider.dart';
import '../services/watch_usage.dart';
import '../theme/app_theme.dart';
import 'common.dart';

/// Diagnostics: how the watch is used and what that does to its battery -
/// drain with the screen on and off, how long a charge lasts, the busiest
/// hours, where the battery goes, problems and upkeep.
class WatchUsageSection extends ConsumerWidget {
  const WatchUsageSection({super.key});

  static String _dur(int s) {
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    return m >= 60 ? '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m' : '${m}m';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(usageProvider);
    final u = st.usage;
    final connected = ref.watch(bleProvider).isConnected;
    final link = ref.watch(companionProvider);
    final upd = ref.watch(updateProvider);

    if (u == null) {
      return Panel(
        child: Row(
          children: [
            Expanded(
              child: Text(
                !connected
                    ? 'Connect the watch to see how it\'s used'
                    : st.asking
                    ? 'Asking the watch...'
                    : 'The watch hasn\'t sent its usage yet (firmware 3.5 or newer)',
                style: const TextStyle(color: AppColors.textDim),
              ),
            ),
            if (connected)
              TextButton(onPressed: () => ref.read(usageProvider.notifier).request(), child: const Text('Ask')),
          ],
        ),
      );
    }

    final rates = u.drainRates();
    final life = u.fullChargeHours();
    final shares = u.drainShares();
    final mah = ref.watch(watchBatteryMahProvider);
    final costs = u.featureCosts(batteryMah: mah);
    final peaks = u.peakHours();
    final findings = usageFindings(
      u,
      crashReport: (link.crashReport ?? '').isNotEmpty,
      firmwareUpdate: upd.firmwareUpdateFor(link.watchFirmware),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- the headline numbers
        Row(
          children: [
            Expanded(
              child: StatTile(
                icon: Icons.battery_charging_full_rounded,
                color: AppColors.success,
                value: life == null ? '--' : (life >= 48 ? '${(life / 24).toStringAsFixed(1)} d' : '${life.round()} h'),
                label: 'a charge lasts',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                icon: Icons.phone_android_rounded,
                color: AppColors.accent,
                value: _dur(u.screenOnTodayS),
                label: 'screen on today',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                icon: Icons.touch_app_rounded,
                color: AppColors.accent2,
                value: '${u.wakes}',
                label: 'wake-ups',
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Battery, last 24 hours', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              SizedBox(
                height: 110,
                width: double.infinity,
                child: CustomPaint(painter: _BatteryChart(u)),
              ),
              const SizedBox(height: 8),
              Text(
                rates == null
                    ? 'Drain: needs a few unplugged hours of data'
                    : 'Drain: ${rates.on.toStringAsFixed(1)}%/h with the screen on, '
                          '${rates.off.toStringAsFixed(1)}%/h off · charged ${u.chargesToday()}× · green = charging',
                style: const TextStyle(color: AppColors.textDim, fontSize: 12.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Screen time by hour, today', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              SizedBox(
                height: 80,
                width: double.infinity,
                child: CustomPaint(painter: _HoursChart(u.onToday, {for (final p in peaks) p.$1})),
              ),
              const SizedBox(height: 6),
              Text(
                peaks.isEmpty
                    ? 'No screen time yet today'
                    : 'Busiest: ${peaks.map((p) => '${p.$1}:00 (${_dur(p.$2)})').join(', ')}',
                style: const TextStyle(color: AppColors.textDim, fontSize: 12.5),
              ),
            ],
          ),
        ),
        if (costs.isNotEmpty) ...[
          const SectionLabel('Battery cost per feature, today'),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (name, what, secs, pct) in costs)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                              Text(
                                '$what · ${_dur(secs)}',
                                style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          pct < 0.5 ? '<1%' : '~${pct.round()}%',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  'Of a full battery. The screen is measured from the drain; the others are estimated from how long '
                  'they were on and their typical draw (a $mah mAh battery - change it in the battery profiler).',
                  style: const TextStyle(color: AppColors.textFaint, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (u.profile != null) ...[
          const SectionLabel('Battery profiler, today'),
          _ProfilerCard(u, mah),
          const SizedBox(height: 10),
        ],
        if (shares.isNotEmpty) ...[
          const SectionLabel('Where the battery goes'),
          Panel(
            child: Column(
              children: [
                for (final (name, pct) in shares.take(8))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        SizedBox(width: 130, child: Text(name, overflow: TextOverflow.ellipsis)),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: pct / 100,
                              minHeight: 8,
                              backgroundColor: AppColors.surfaceHigh,
                              color: name.startsWith('Standby') ? AppColors.textDim : AppColors.warning,
                            ),
                          ),
                        ),
                        SizedBox(width: 44, child: Text('${pct.round()}%', textAlign: TextAlign.right)),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                const Text(
                  'Estimated from each app\'s screen time today and the screen-on drain; the watch has no per-app power meter.',
                  style: TextStyle(color: AppColors.textFaint, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
        if (u.week.isNotEmpty) ...[
          const SectionLabel('Last 7 days, on the watch'),
          Panel(
            child: Column(
              children: [
                for (final d in u.week)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 54,
                          child: Text(
                            const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.date.weekday - 1],
                            style: const TextStyle(color: AppColors.textDim),
                          ),
                        ),
                        Expanded(child: Text('${_dur(d.onMin * 60)} on screen')),
                        SizedBox(width: 74, child: Text('${d.dropPct}% used', textAlign: TextAlign.right)),
                        SizedBox(
                          width: 70,
                          child: Text(
                            d.charges == 0 ? '' : '${d.charges}× charged',
                            textAlign: TextAlign.right,
                            style: const TextStyle(color: AppColors.textDim, fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SectionLabel('Issues & upkeep'),
        RowGroup(
          children: [
            for (final f in findings)
              ListTile(
                leading: Icon(
                  switch (f.severity) {
                    Severity.bad => Icons.error_rounded,
                    Severity.warn => Icons.warning_amber_rounded,
                    Severity.info => Icons.info_outline_rounded,
                    Severity.ok => Icons.check_circle_rounded,
                  },
                  color: switch (f.severity) {
                    Severity.bad => AppColors.danger,
                    Severity.warn => AppColors.warning,
                    Severity.info => AppColors.accent2,
                    Severity.ok => AppColors.success,
                  },
                ),
                title: Text(f.title),
                subtitle: Text(f.detail),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Panel(
          child: Column(
            children: [
              _row('Today', '${u.notifications} notifications · ${u.disconnects} Bluetooth drops'),
              _row('Up for', _dur(u.uptimeS)),
              _row('Restarts', '${u.boots} in all · ${u.crashes} crashes · last: ${u.resetReason}'),
              _row('Memory', 'lowest free ${u.minHeapKb} KB · PSRAM ${(u.psramKb / 1024).toStringAsFixed(1)} MB free'),
              if (u.sdTotalMb != null)
                _row(
                  'SD card',
                  '${((u.sdTotalMb! - (u.sdUsedMb ?? 0)) / 1024).toStringAsFixed(1)} GB free of ${(u.sdTotalMb! / 1024).toStringAsFixed(1)} GB',
                ),
              if (st.week.length > 12) _row('This week', _weekSummary(st.week)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: connected && !st.asking ? () => ref.read(usageProvider.notifier).request() : null,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Ask the watch again'),
          ),
        ),
      ],
    );
  }

  static String _weekSummary(List<(DateTime, int, bool)> w) {
    // charges started and the average daily low, from the phone's readings
    var charges = 0;
    for (var i = 1; i < w.length; i++) {
      if (w[i].$3 && !w[i - 1].$3) charges++;
    }
    final days = math.max(1, w.last.$1.difference(w.first.$1).inHours / 24).round();
    final low = w.map((x) => x.$2).reduce(math.min);
    return '$charges charges in $days days · lowest $low%';
  }

  static Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 86,
          child: Text(k, style: const TextStyle(color: AppColors.textDim)),
        ),
        Expanded(child: Text(v)),
      ],
    ),
  );
}

/// The battery over 24 h: a line, green where it was charging.
class _BatteryChart extends CustomPainter {
  final WatchUsage u;
  _BatteryChart(this.u);

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = AppColors.surfaceHigh
      ..strokeWidth = 1;
    for (final f in [0.0, 0.5, 1.0]) {
      canvas.drawLine(Offset(0, size.height * f), Offset(size.width, size.height * f), grid);
    }
    final n = u.battery.length;
    if (n < 2) return;
    Offset pt(int i, int v) => Offset(size.width * i / (n - 1), size.height * (1 - v / 100));
    for (var i = 1; i < n; i++) {
      final a = u.battery[i - 1], b = u.battery[i];
      if (a == null || b == null) continue;
      canvas.drawLine(
        pt(i - 1, a),
        pt(i, b),
        Paint()
          ..color = u.charging[i] ? AppColors.success : AppColors.accent
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );
    }
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final (f, label) in [(0.0, '100%'), (1.0, '0%')]) {
      tp.text = TextSpan(
        text: label,
        style: const TextStyle(color: AppColors.textFaint, fontSize: 10),
      );
      tp.layout();
      tp.paint(canvas, Offset(0, f == 0 ? 2 : size.height - tp.height - 2));
    }
  }

  @override
  bool shouldRepaint(_BatteryChart o) => o.u != u;
}

/// Screen-on minutes per hour, the busiest hours highlighted.
class _HoursChart extends CustomPainter {
  final List<int> on;
  final Set<int> peaks;
  _HoursChart(this.on, this.peaks);

  @override
  void paint(Canvas canvas, Size size) {
    if (on.length != 24) return;
    final maxV = math.max(60, on.reduce(math.max)).toDouble();
    final w = size.width / 24;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var h = 0; h < 24; h++) {
      final hgt = (size.height - 14) * on[h] / maxV;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(h * w + 1.5, size.height - 14 - hgt, w - 3, math.max(2, hgt)),
        const Radius.circular(3),
      );
      canvas.drawRRect(
        r,
        Paint()..color = peaks.contains(h) ? AppColors.warning : AppColors.accent.withValues(alpha: 0.7),
      );
      if (h % 6 == 0) {
        tp.text = TextSpan(
          text: '$h',
          style: const TextStyle(color: AppColors.textFaint, fontSize: 10),
        );
        tp.layout();
        tp.paint(canvas, Offset(h * w, size.height - 12));
      }
    }
  }

  @override
  bool shouldRepaint(_HoursChart o) => o.on != on;
}

/// Diagnostics: the watch's own measurement (power_profile.cpp) - with the
/// screen off or on, how much of the time it slept, what held it awake,
/// and the drain shared out over the features (mA from the measured drain
/// and the battery's capacity).
class _ProfilerCard extends ConsumerStatefulWidget {
  final WatchUsage usage;
  final int mah;
  const _ProfilerCard(this.usage, this.mah);
  @override
  ConsumerState<_ProfilerCard> createState() => _ProfilerCardState();
}

class _ProfilerCardState extends ConsumerState<_ProfilerCard> {
  bool _on = false; // false: screen off

  Future<void> _editBattery() async {
    final ctl = TextEditingController(text: '${widget.mah}');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Watch battery'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(suffixText: 'mAh', helperText: 'The capacity printed on the cell'),
          onSubmitted: (t) => Navigator.pop(ctx, int.tryParse(t.trim())),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, int.tryParse(ctl.text.trim())), child: const Text('Save')),
        ],
      ),
    );
    if (v != null) await ref.read(watchBatteryMahProvider.notifier).set(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.usage.profile!;
    final w = _on ? p.on : p.off;
    final rates = widget.usage.drainRates();
    final pctH = rates == null ? null : (_on ? rates.on : rates.off);
    final mA = pctH == null ? null : pctH / 100 * widget.mah;
    final rows = w == null ? const <DrainShare>[] : PowerProfile.breakdown(w, measuredMa: mA);
    String dur(int s) => s >= 3600 ? '${s ~/ 3600}h ${(s % 3600 ~/ 60).toString().padLeft(2, '0')}m' : '${s ~/ 60}m';
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Screen off')),
              ButtonSegment(value: true, label: Text('Screen on')),
            ],
            selected: {_on},
            onSelectionChanged: (v) => setState(() => _on = v.first),
          ),
          const SizedBox(height: 12),
          if (w == null)
            Text(
              _on ? 'No screen-on time measured yet today' : 'No screen-off time measured yet today',
              style: const TextStyle(color: AppColors.textDim),
            )
          else ...[
            Text(
              [
                '${dur(w.seconds)} measured',
                if (w.sleepPermille != null) 'asleep ${(w.sleepPermille! / 10).round()}% of it',
                if (mA != null) 'about ${mA.toStringAsFixed(mA < 10 ? 1 : 0)} mA (${pctH!.toStringAsFixed(1)}%/h)',
              ].join(' · '),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (w.locks.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Held awake: ${[for (final (n, pm) in w.locks.take(4)) '${PowerProfile.lockLabel(n)} ${(pm / 10).round()}%'].join(', ')}',
                style: const TextStyle(color: AppColors.textDim, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 10),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(r.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                        Text(
                          r.mA != null
                              ? '${r.mA!.toStringAsFixed(r.mA! < 10 ? 1 : 0)} mA · ${(r.share * 100).round()}%'
                              : '${(r.share * 100).round()}%',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: r.share,
                        minHeight: 6,
                        backgroundColor: AppColors.surfaceHigh,
                        color: r.label == 'Asleep'
                            ? AppColors.success
                            : r.label.startsWith('Awake')
                            ? AppColors.danger
                            : AppColors.warning,
                      ),
                    ),
                    if (r.detail.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(r.detail, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                      ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Measured on the watch: time asleep, power locks and CPU per task. The mA are the measured drain '
                  'shared out by typical draw - estimates, for a ${widget.mah} mAh battery.',
                  style: const TextStyle(color: AppColors.textFaint, fontSize: 11.5),
                ),
              ),
              TextButton(onPressed: _editBattery, child: const Text('Battery size')),
            ],
          ),
        ],
      ),
    );
  }
}
