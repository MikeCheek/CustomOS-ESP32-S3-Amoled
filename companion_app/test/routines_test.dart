import 'package:flutter_test/flutter_test.dart';
import 'package:amoled_companion/services/assistant_intents.dart';
import 'package:amoled_companion/services/routines.dart';

void main() {
  test('a routine is called by its phrase or its name', () {
    expect(matchRoutine('Good night!', defaultRoutines)?.name, 'Good night');
    expect(matchRoutine('Buonanotte', defaultRoutines)?.name, 'Good night');
    expect(matchRoutine('run the heading out routine', defaultRoutines)?.name, 'Heading out');
    expect(matchRoutine('Good night, set an alarm at 6', defaultRoutines), isNull); // more than the phrase
    expect(matchRoutine('What is the weather', defaultRoutines), isNull);
  });

  test('each step is a command the assistant already understands', () {
    final now = DateTime(2026, 11, 8, 22, 30);
    final kinds = {
      StepKind.dndOn: IntentKind.dnd,
      StepKind.dndOff: IntentKind.dnd,
      StepKind.alarm: IntentKind.reminder,
      StepKind.timer: IntentKind.timer,
      StepKind.weather: IntentKind.weather,
      StepKind.agenda: IntentKind.agenda,
      StepKind.musicPlay: IntentKind.music,
      StepKind.musicPause: IntentKind.music,
      StepKind.battery: IntentKind.battery,
    };
    for (final e in kinds.entries) {
      final cmd = stepCommand(RoutineStep(e.key, e.key == StepKind.alarm ? 7 * 60 : 10))!;
      expect(parseAssistantIntent(cmd, now).kind, e.value, reason: cmd);
    }
    expect(parseAssistantIntent(stepCommand(const RoutineStep(StepKind.dndOff))!, now).on, isFalse);
    expect(
      parseAssistantIntent(stepCommand(const RoutineStep(StepKind.alarm, 420))!, now).at,
      DateTime(2026, 11, 9, 7),
    );
    expect(stepCommand(const RoutineStep(StepKind.recap)), isNull);
  });

  test('saved and read back', () {
    final r = Routine.fromJson(defaultRoutines.first.toJson());
    expect(r.name, 'Good night');
    expect(r.phrases, ['good night', 'goodnight', 'buonanotte']);
    expect(r.steps.map((s) => s.label).toList(), ['Do not disturb on', 'Alarm at 07:00', 'The evening recap']);
  });
}
