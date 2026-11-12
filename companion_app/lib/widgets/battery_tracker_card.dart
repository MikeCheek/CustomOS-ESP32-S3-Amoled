import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/usage_provider.dart';
import '../services/battery_tracker.dart';
import '../theme/app_theme.dart';
import 'common.dart';

/// Diagnostics: the battery tracker - what each feature cost over the last
/// 24 hours, hour by hour, and what switching one off would give back.
class BatteryTrackerSection extends ConsumerWidget {
  const BatteryTrackerSection({super.key});

  static const groupColors = {
    EnergyGroup.screen: AppColors.accent,
    EnergyGroup.standby: AppColors.textDim,
    EnergyGroup.radio: AppColors.accent2,
    EnergyGroup.gps: AppColors.success,
    EnergyGroup.audio: AppColors.accent3,
    EnergyGroup.aod: AppColors.warning,
    EnergyGroup.events: Color(0xFFB9A8FF),
  };

  static String _h(double x) {
    if (x < 1 / 60) return '${(x * 3600).round()}s';
    if (x < 1) return '${(x * 60).round()}m';
    return '${x.floor()}h ${((x - x.floor()) * 60).round().toString().padLeft(2, '0')}m';
  }

  static String _ma(double v) => v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(usageProvider);
    final log = st.energy;
    if (log == null) {
      if (st.usage == null) return const SizedBox.shrink(); // the usage section already says why
      return const Panel(
        child: Text(
          'Per-feature battery tracking needs watch firmware 3.5 or newer, and its first 10 minutes of log.',
          style: TextStyle(color: AppColors.textDim),
        ),
      );
    }
    final r = st.tracker;
    if (r == null) {
      return Panel(
        child: Text(
          'The watch has logged ${log.slots.length * log.intervalMin} min, almost all of it plugged in. '
          'Check back after some time off the charger.',
          style: const TextStyle(color: AppColors.textDim),
        ),
      );
    }
    final life = r.fullChargeHours;
    final sleep = r.sleepShare;
    final notes = trackerFindings(r);
    final shown = r.costs.where((c) => c.mah >= 0.05 || c.amount > 0).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                icon: Icons.bolt_rounded,
                color: AppColors.warning,
                value: '${_ma(r.averageMa)} mA',
                label: 'average draw',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                icon: Icons.nightlight_round,
                color: AppColors.accent2,
                value: '${_ma(r.screenOffMa)} mA',
                label: sleep == null ? 'screen off' : 'off · ${(sleep * 100).round()}% asleep',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                icon: Icons.battery_full_rounded,
                color: AppColors.success,
                value: life == null ? '--' : (life >= 48 ? '${(life / 24).toStringAsFixed(1)} d' : '${life.round()} h'),
                label: 'at this use',
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Battery use by hour', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              SizedBox(
                height: 120,
                width: double.infinity,
                child: CustomPaint(painter: _StackChart(r.hours)),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  for (final g in EnergyGroup.values)
                    if (r.hours.any((h) => (h.mah[g] ?? 0) > 0.05))
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(color: groupColors[g], borderRadius: BorderRadius.circular(2)),
                          ),
                          const SizedBox(width: 4),
                          Text(energyGroupLabels[g]!, style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                        ],
                      ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'mAh per hour, last ${r.hours.length} h · grey = on the charger · '
                '${r.percentPerDay.toStringAsFixed(0)}%/day at this use',
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
              Row(
                children: [
                  const Expanded(child: Text('Where it went', style: TextStyle(fontWeight: FontWeight.w600))),
                  Text(
                    '${r.totalMah.toStringAsFixed(0)} mAh in ${_h(r.unpluggedHours)}',
                    style: const TextStyle(color: AppColors.textDim, fontSize: 12.5),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final c in shown) _FeatureRow(c, r),
              const SizedBox(height: 6),
              Text(
                '● measured from your battery · ○ typical for this watch (not enough varied use to measure yet). '
                'Based on ${r.windows} unplugged hour${r.windows == 1 ? '' : 's'}.',
                style: const TextStyle(color: AppColors.textFaint, fontSize: 11.5),
              ),
            ],
          ),
        ),
        for (final n in notes) ...[
          const SizedBox(height: 8),
          Panel(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  n.$1 ? Icons.warning_amber_rounded : Icons.info_outline_rounded,
                  color: n.$1 ? AppColors.warning : AppColors.accent2,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(n.$2, style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(n.$3, style: const TextStyle(color: AppColors.textDim, fontSize: 12.5)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _editCapacity(context, ref, st.batteryMah),
            icon: const Icon(Icons.battery_std_rounded, size: 18),
            label: Text('Battery: ${st.batteryMah} mAh'),
          ),
        ),
      ],
    );
  }

  static Future<void> _editCapacity(BuildContext context, WidgetRef ref, int mah) async {
    final ctl = TextEditingController(text: '$mah');
    final v = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Battery capacity'),
        content: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(suffixText: 'mAh', helperText: 'As printed on the cell'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, int.tryParse(ctl.text.trim())), child: const Text('Save')),
        ],
      ),
    );
    ctl.dispose();
    if (v != null) await ref.read(usageProvider.notifier).setBatteryMah(v);
  }
}

class _FeatureRow extends StatelessWidget {
  final FeatureCost c;
  final TrackerReport r;
  const _FeatureRow(this.c, this.r);

  @override
  Widget build(BuildContext context) {
    final color = BatteryTrackerSection.groupColors[c.info.group]!;
    final gain = r.hoursGainedWithout(c.feature);
    final use = c.info.count
        ? '${c.amount.round()}×, ~${(c.current * 1000).toStringAsFixed(0)} µAh each'
        : '${BatteryTrackerSection._h(c.amount)} · ${BatteryTrackerSection._ma(c.current)} mA'
              '${c.measured ? ' ±${BatteryTrackerSection._ma(c.sd)}' : ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(c.measured ? '● ' : '○ ', style: TextStyle(color: color, fontSize: 12)),
              Expanded(child: Text(c.info.label)),
              Text(
                '${c.mah.toStringAsFixed(c.mah >= 10 ? 0 : 1)} mAh · ${(c.share * 100).toStringAsFixed(c.share < 0.1 ? 1 : 0)}%',
                style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: c.share.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: AppColors.surfaceHigh,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            gain != null && gain >= 0.5 ? '$use · off: +${gain >= 24 ? '${(gain / 24).toStringAsFixed(1)} d' : '${gain.round()} h'} a charge' : use,
            style: const TextStyle(color: AppColors.textDim, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// mAh per hour, stacked by group; charging hours greyed.
class _StackChart extends CustomPainter {
  final List<TrackerHour> hours;
  _StackChart(this.hours);

  @override
  void paint(Canvas canvas, Size size) {
    if (hours.isEmpty) return;
    const foot = 14.0;
    final h = size.height - foot;
    final maxV = math.max(5.0, hours.map((x) => x.total).reduce(math.max));
    const slots = 24;
    final w = size.width / slots;
    final x0 = size.width - hours.length * w; // newest at the right
    final tp = TextPainter(textDirection: TextDirection.ltr);
    final grid = Paint()
      ..color = AppColors.surfaceHigh
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, h), Offset(size.width, h), grid);
    for (var i = 0; i < hours.length; i++) {
      final hr = hours[i];
      final left = x0 + i * w + 1.5;
      if (hr.plugged && hr.total < 0.05) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(left, h - 4, w - 3, 4), const Radius.circular(2)),
          Paint()..color = AppColors.surfaceHigh,
        );
      } else {
        var y = h;
        for (final g in EnergyGroup.values) {
          final v = hr.mah[g] ?? 0;
          if (v <= 0) continue;
          final bh = h * v / maxV;
          canvas.drawRect(
            Rect.fromLTWH(left, y - bh, w - 3, bh),
            Paint()..color = BatteryTrackerSection.groupColors[g]!.withValues(alpha: hr.plugged ? 0.35 : 0.9),
          );
          y -= bh;
        }
      }
      final hour = hr.end.hour;
      if (hour % 6 == 0) {
        tp.text = TextSpan(
          text: '$hour:00',
          style: const TextStyle(color: AppColors.textFaint, fontSize: 10),
        );
        tp.layout();
        tp.paint(canvas, Offset(math.min(size.width - tp.width, left), size.height - 12));
      }
    }
    tp.text = TextSpan(
      text: '${maxV.toStringAsFixed(0)} mAh',
      style: const TextStyle(color: AppColors.textFaint, fontSize: 10),
    );
    tp.layout();
    tp.paint(canvas, const Offset(0, 0));
  }

  @override
  bool shouldRepaint(_StackChart o) => o.hours != hours;
}
