import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Routines: one phrase to the assistant (or Run in the app) does several
/// things - "good night": Do not disturb on, the alarm at 7:00, the evening
/// recap. Each step is said to the assistant as a plain command
/// ([stepCommand]), so a routine does exactly what asking for each thing
/// would do. Kept in the app (AI models > Routines).
enum StepKind { dndOn, dndOff, alarm, timer, weather, agenda, recap, musicPlay, musicPause, battery }

class RoutineStep {
  final StepKind kind;
  final int value; // alarm: minute of the day; timer: minutes
  const RoutineStep(this.kind, [this.value = 0]);

  Map<String, dynamic> toJson() => {'k': kind.name, if (value != 0) 'v': value};
  static RoutineStep? fromJson(Map<String, dynamic> j) {
    final k = StepKind.values.where((e) => e.name == j['k']).firstOrNull;
    return k == null ? null : RoutineStep(k, (j['v'] as num?)?.toInt() ?? 0);
  }

  String get label => switch (kind) {
    StepKind.dndOn => 'Do not disturb on',
    StepKind.dndOff => 'Do not disturb off',
    StepKind.alarm => 'Alarm at ${hm(value)}',
    StepKind.timer => 'Timer $value min',
    StepKind.weather => 'Say the weather',
    StepKind.agenda => 'Say the agenda',
    StepKind.recap => 'The evening recap',
    StepKind.musicPlay => 'Play music',
    StepKind.musicPause => 'Pause music',
    StepKind.battery => 'Say the battery',
  };
}

String hm(int minute) => '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

class Routine {
  final String name;
  final List<String> phrases; // what to say, lower case ("good night", "buonanotte")
  final List<RoutineStep> steps;
  const Routine(this.name, this.phrases, this.steps);

  Map<String, dynamic> toJson() => {
    'n': name,
    'p': phrases,
    's': [for (final s in steps) s.toJson()],
  };
  static Routine fromJson(Map<String, dynamic> j) => Routine(
    j['n'] as String? ?? 'Routine',
    [for (final p in (j['p'] as List? ?? const [])) '$p'],
    [
      for (final s in (j['s'] as List? ?? const []))
        if (s is Map && RoutineStep.fromJson(Map<String, dynamic>.from(s)) != null)
          RoutineStep.fromJson(Map<String, dynamic>.from(s))!,
    ],
  );
}

const defaultRoutines = [
  Routine(
    'Good night',
    ['good night', 'goodnight', 'buonanotte'],
    [RoutineStep(StepKind.dndOn), RoutineStep(StepKind.alarm, 7 * 60), RoutineStep(StepKind.recap)],
  ),
  Routine(
    'Good morning',
    ['good morning', 'buongiorno'],
    [RoutineStep(StepKind.dndOff), RoutineStep(StepKind.weather), RoutineStep(StepKind.agenda)],
  ),
  Routine(
    'Heading out',
    ['heading out', 'i\'m leaving', 'sto uscendo', 'esco'],
    [RoutineStep(StepKind.weather), RoutineStep(StepKind.agenda), RoutineStep(StepKind.battery)],
  ),
];

/// What the assistant is told for a step; null: not a command (the recap).
String? stepCommand(RoutineStep s) => switch (s.kind) {
  StepKind.dndOn => 'turn on do not disturb',
  StepKind.dndOff => 'turn off do not disturb',
  StepKind.alarm => 'set an alarm at ${hm(s.value)}',
  StepKind.timer => 'set a timer for ${s.value} minutes',
  StepKind.weather => 'what\'s the weather',
  StepKind.agenda => 'what\'s on my agenda',
  StepKind.musicPlay => 'play music',
  StepKind.musicPause => 'pause the music',
  StepKind.battery => 'how much battery',
  StepKind.recap => null,
};

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r"[^\p{L}\p{N}' ]", unicode: true), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// The routine [heard] calls for: the whole request is one of its phrases
/// (give or take "run" / "start" and the wake word's leftovers), or null.
Routine? matchRoutine(String heard, List<Routine> routines) {
  var s = _norm(heard);
  s = s.replaceFirst(RegExp(r'^(hey |ok |okay )?(run |start |do |avvia |esegui )?(the |la |il )?(routine )?'), '');
  s = s.replaceFirst(RegExp(r' (routine|please|per favore)$'), '');
  for (final r in routines) {
    for (final p in r.phrases) {
      if (_norm(p) == s) return r;
    }
    if (_norm(r.name) == s) return r;
  }
  return null;
}

class Routines {
  static Future<List<Routine>> load() async {
    final raw = (await SharedPreferences.getInstance()).getString('routines');
    if (raw == null) return List.of(defaultRoutines);
    try {
      return [for (final j in jsonDecode(raw) as List) Routine.fromJson(Map<String, dynamic>.from(j as Map))];
    } catch (_) {
      return List.of(defaultRoutines);
    }
  }

  static Future<void> save(List<Routine> l) async =>
      (await SharedPreferences.getInstance()).setString('routines', jsonEncode([for (final r in l) r.toJson()]));
}
