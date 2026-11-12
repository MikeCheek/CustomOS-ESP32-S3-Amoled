import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:amoled_companion/providers/companion_provider.dart';
import 'package:amoled_companion/providers/knowledge_provider.dart';
import 'package:amoled_companion/services/ble_protocol.dart';
import 'package:amoled_companion/services/knowledge_base.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final memo = RecordingEntry(name: 'rec_001.wav', actions: ['Call Marco', 'Buy milk']);
  final actions = [for (final a in memo.actions) ActionItem(memo, a)];

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('memo to-dos come through unchanged without edits', () {
    final l = applyTodoEdits(actions, const TodoEdits());
    expect(l.map((t) => t.text), ['Call Marco', 'Buy milk']);
    expect(l.first.key, 'rec_001.wav|Call Marco');
    expect(l.first.manual, isFalse);
  });

  test('add, reword, restore and remove', () async {
    final n = TodoEditsNotifier();
    await Future<void>.delayed(Duration.zero);

    final key = await n.add('  Book the dentist ');
    var l = applyTodoEdits(actions, n.state);
    expect(l.first.text, 'Book the dentist'); // hand-made ones first, trimmed
    expect(l.first.manual, isTrue);
    expect(l.first.key, key);

    // rewording a memo's to-do keeps its key (done state, the watch's id)
    final call = l.firstWhere((t) => t.text == 'Call Marco');
    await n.edit(call, 'Call Marco about Friday');
    l = applyTodoEdits(actions, n.state);
    final edited = l.firstWhere((t) => t.key == call.key);
    expect(edited.text, 'Call Marco about Friday');
    expect(edited.edited, isTrue);
    expect(CompanionNotifier.todoKey(edited.key), CompanionNotifier.todoKey(call.key));

    // the memo's own wording again: no longer an edit
    await n.edit(edited, 'Call Marco');
    l = applyTodoEdits(actions, n.state);
    expect(l.firstWhere((t) => t.key == call.key).edited, isFalse);

    // a hand-made one edited, then both kinds removed
    await n.edit(l.first, 'Book the dentist for Monday');
    expect(applyTodoEdits(actions, n.state).first.text, 'Book the dentist for Monday');
    await n.remove(applyTodoEdits(actions, n.state).first);
    await n.remove(applyTodoEdits(actions, n.state).firstWhere((t) => t.text == 'Buy milk'));
    expect(applyTodoEdits(actions, n.state).map((t) => t.text), ['Call Marco']);

    // a blank one isn't added
    expect(await n.add('   '), isNull);
  });

  test('kept across restarts', () async {
    final n = TodoEditsNotifier();
    await Future<void>.delayed(Duration.zero);
    await n.add('Water the plants');
    await n.edit(applyTodoEdits(actions, n.state).firstWhere((t) => t.text == 'Buy milk'), 'Buy oat milk');

    final again = TodoEditsNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final l = applyTodoEdits(actions, again.state);
    expect(l.map((t) => t.text), ['Water the plants', 'Call Marco', 'Buy oat milk']);
  });
}
