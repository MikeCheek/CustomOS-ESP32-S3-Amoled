import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/companion_provider.dart';
import '../services/routines.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// Routines (routines.dart): say the phrase to the assistant, or Run here.
class RoutinesScreen extends ConsumerStatefulWidget {
  const RoutinesScreen({super.key});

  @override
  ConsumerState<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends ConsumerState<RoutinesScreen> {
  List<Routine>? _list;
  String? _running;

  @override
  void initState() {
    super.initState();
    Routines.load().then((l) {
      if (mounted) setState(() => _list = l);
    });
  }

  Future<void> _save(List<Routine> l) async {
    await Routines.save(l);
    if (mounted) setState(() => _list = l);
  }

  Future<void> _edit([int? i]) async {
    final l = _list!;
    final r = await Navigator.of(
      context,
    ).push<Routine>(MaterialPageRoute(builder: (_) => _RoutineEditor(i == null ? null : l[i])));
    if (r == null) return;
    final n = List.of(l);
    if (i == null) {
      n.add(r);
    } else {
      n[i] = r;
    }
    await _save(n);
  }

  Future<void> _run(Routine r) async {
    setState(() => _running = r.name);
    String text;
    try {
      text = await ref.read(companionProvider.notifier).runRoutine(r);
    } catch (e) {
      text = e.toString().replaceFirst('Exception: ', '');
    }
    if (!mounted) return;
    setState(() => _running = null);
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(r.name),
        content: Text(text),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Routines'),
        actions: [
          IconButton(tooltip: 'New routine', icon: const Icon(Icons.add_rounded), onPressed: l == null ? null : _edit),
        ],
      ),
      body: l == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                const Text(
                  'Say a routine\'s phrase to the assistant on the watch - "good night" - and it does every step, '
                  'then says how it went. Or run it from here.',
                  style: TextStyle(color: AppColors.textDim, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 12),
                for (final (i, r) in l.indexed) ...[
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                r.name,
                                style: const TextStyle(
                                  color: AppColors.text,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Edit',
                              icon: const Icon(Icons.edit_outlined, color: AppColors.textDim),
                              onPressed: () => _edit(i),
                            ),
                            IconButton(
                              tooltip: 'Delete',
                              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.textDim),
                              onPressed: () => _save(List.of(l)..removeAt(i)),
                            ),
                          ],
                        ),
                        Text(
                          'Say: ${r.phrases.map((p) => '"$p"').join(' or ')}',
                          style: const TextStyle(color: AppColors.textDim, fontSize: 12.5),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final s in r.steps) Chip(label: Text(s.label, style: const TextStyle(fontSize: 12))),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                            onPressed: _running != null ? null : () => _run(r),
                            icon: _running == r.name
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.play_arrow_rounded, size: 18),
                            label: const Text('Run'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                if (l.isEmpty)
                  TextButton(
                    onPressed: () => _save(List.of(defaultRoutines)),
                    child: const Text('Bring back the examples'),
                  ),
              ],
            ),
    );
  }
}

class _RoutineEditor extends StatefulWidget {
  final Routine? routine;
  const _RoutineEditor(this.routine);

  @override
  State<_RoutineEditor> createState() => _RoutineEditorState();
}

class _RoutineEditorState extends State<_RoutineEditor> {
  late final _name = TextEditingController(text: widget.routine?.name ?? '');
  late final _phrases = TextEditingController(text: widget.routine?.phrases.join(', ') ?? '');
  late final Map<StepKind, int?> _on = {
    for (final k in StepKind.values) k: widget.routine?.steps.where((s) => s.kind == k).firstOrNull?.value,
  }; // null: not in the routine
  late final Set<StepKind> _picked = {for (final s in widget.routine?.steps ?? const <RoutineStep>[]) s.kind};

  @override
  void dispose() {
    _name.dispose();
    _phrases.dispose();
    super.dispose();
  }

  void _done() {
    final name = _name.text.trim();
    final phrases = [
      for (final p in _phrases.text.split(','))
        if (p.trim().isNotEmpty) p.trim().toLowerCase(),
    ];
    if (name.isEmpty || _picked.isEmpty) {
      showSnack(context, 'Give it a name and at least one step');
      return;
    }
    Navigator.pop(
      context,
      Routine(name, phrases.isEmpty ? [name.toLowerCase()] : phrases, [
        for (final k in StepKind.values)
          if (_picked.contains(k))
            RoutineStep(k, _on[k] ?? (k == StepKind.alarm ? 7 * 60 : (k == StepKind.timer ? 10 : 0))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.routine == null ? 'New routine' : 'Edit routine'),
        actions: [TextButton(onPressed: _done, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _phrases,
            decoration: const InputDecoration(
              labelText: 'Phrases to say',
              helperText: 'Separated by commas: good night, buonanotte',
            ),
          ),
          const SectionLabel('Steps, in this order'),
          for (final k in StepKind.values)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _picked.contains(k),
              onChanged: (v) => setState(() => v == true ? _picked.add(k) : _picked.remove(k)),
              title: Text(RoutineStep(k, _on[k] ?? (k == StepKind.alarm ? 420 : 10)).label),
              secondary: k == StepKind.alarm || k == StepKind.timer
                  ? IconButton(
                      tooltip: k == StepKind.alarm ? 'Change the time' : 'Change the minutes',
                      icon: const Icon(Icons.tune_rounded),
                      onPressed: () async {
                        if (k == StepKind.alarm) {
                          final m = _on[k] ?? 420;
                          final t = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
                          );
                          if (t != null) setState(() => _on[k] = t.hour * 60 + t.minute);
                        } else {
                          final m = _on[k] ?? 10;
                          setState(() => _on[k] = m >= 60 ? 5 : (m < 15 ? m + 5 : m + 15));
                        }
                      },
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}
