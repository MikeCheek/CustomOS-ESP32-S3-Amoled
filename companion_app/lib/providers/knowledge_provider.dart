import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ble_protocol.dart';
import '../services/gemma_service.dart';
import '../services/knowledge_base.dart';
import 'notes_provider.dart';

/// The search index, collections and statistics over all memos. Rebuilt
/// whenever the memo list changes (a transcript or summary arrives...).
final Provider<KnowledgeBase> knowledgeProvider = Provider<KnowledgeBase>((ref) {
  final recordings = ref.watch(notesProvider.select((s) => s.recordings));
  return KnowledgeBase.build(recordings);
});

/// Names of theme collections: AI-made or set by the user, keyed by the
/// collection's keywords. Kept in SharedPreferences.
class CollectionNamesNotifier extends StateNotifier<Map<String, String>> {
  static const _key = 'collection_names';
  bool _naming = false;

  CollectionNamesNotifier() : super(const {}) {
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    try {
      final m = jsonDecode(p.getString(_key) ?? '{}') as Map<String, dynamic>;
      state = m.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {}
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(state));
  }

  String nameOf(MemoCollection c) => state[c.key] ?? c.autoName;

  Future<void> rename(MemoCollection c, String name) async {
    final n = name.trim();
    state = {...state}..removeWhere((k, _) => k == c.key);
    if (n.isNotEmpty) state = {...state, c.key: n};
    await _save();
  }

  bool get naming => _naming;

  /// Asks the on-device model to name collections that have no name yet.
  /// Returns how many were named (0 without a model).
  Future<int> nameMissing(KnowledgeBase kb, {bool all = false}) async {
    if (_naming) return 0;
    _naming = true;
    var named = 0;
    try {
      if (!await GemmaService.instance.hasModel()) return 0;
      for (final c in kb.collections) {
        if (!all && state.containsKey(c.key)) continue;
        final name = await GemmaService.instance.nameCollection(
          c.keywords,
          c.items.map((e) => e.displayTitle).toList(),
        );
        if (name == null || !mounted) continue;
        state = {...state, c.key: name};
        named++;
      }
      if (named > 0) await _save();
    } catch (e) {
      print('[Knowledge] naming collections: $e');
    } finally {
      _naming = false;
    }
    return named;
  }
}

final StateNotifierProvider<CollectionNamesNotifier, Map<String, String>> collectionNamesProvider =
    StateNotifierProvider<CollectionNamesNotifier, Map<String, String>>((ref) => CollectionNamesNotifier());

/// Action items ticked off (key = memo name + text), in SharedPreferences.
class DoneActionsNotifier extends StateNotifier<Set<String>> {
  static const _key = 'actions_done';
  DoneActionsNotifier() : super(const {}) {
    SharedPreferences.getInstance().then((p) {
      if (mounted) state = (p.getStringList(_key) ?? const []).toSet();
    });
  }

  Future<void> toggle(String key) async {
    state = state.contains(key) ? ({...state}..remove(key)) : {...state, key};
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_key, state.toList());
  }
}

final StateNotifierProvider<DoneActionsNotifier, Set<String>> doneActionsProvider =
    StateNotifierProvider<DoneActionsNotifier, Set<String>>((ref) => DoneActionsNotifier());

// ---- to-dos: from the memos, edited, and added by hand -------------------------------

/// A to-do as the app and the watch show it: one found in a memo (perhaps
/// reworded by the user), or one added by hand.
class Todo {
  /// Stable for the life of the to-do: the done state and the watch's id
  /// (FNV-1a of it) hang on it - editing the text doesn't change it.
  final String key;
  final String text;
  final RecordingEntry? entry; // the memo it came from; null: added by hand
  final bool edited; // a memo's to-do, reworded
  const Todo(this.key, this.text, {this.entry, this.edited = false});
  bool get manual => entry == null;
}

class ManualTodo {
  final String id;
  final String text;
  const ManualTodo(this.id, this.text);
  Map<String, dynamic> toJson() => {'id': id, 'x': text};
  static ManualTodo? fromJson(dynamic j) {
    if (j is! Map || j['id'] is! String || j['x'] is! String) return null;
    return ManualTodo(j['id'] as String, j['x'] as String);
  }
}

/// What the user changed: to-dos added by hand (newest first), memos'
/// to-dos reworded (original key -> text) or removed.
class TodoEdits {
  final List<ManualTodo> manual;
  final Map<String, String> text;
  final Set<String> removed;
  const TodoEdits({this.manual = const [], this.text = const {}, this.removed = const {}});
}

class TodoEditsNotifier extends StateNotifier<TodoEdits> {
  static const _key = 'todo_edits';
  TodoEditsNotifier() : super(const TodoEdits()) {
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    try {
      final j = jsonDecode(p.getString(_key) ?? '{}') as Map<String, dynamic>;
      if (!mounted) return;
      state = TodoEdits(
        manual: [
          for (final m in (j['manual'] as List? ?? const [])) ManualTodo.fromJson(m),
        ].whereType<ManualTodo>().toList(),
        text: (j['text'] as Map? ?? const {}).map((k, v) => MapEntry(k.toString(), v.toString())),
        removed: {for (final r in (j['removed'] as List? ?? const [])) r.toString()},
      );
    } catch (_) {}
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key,
      jsonEncode({
        'manual': [for (final m in state.manual) m.toJson()],
        'text': state.text,
        'removed': state.removed.toList(),
      }),
    );
  }

  /// A new to-do, at the top of the list. Returns its key.
  Future<String?> add(String text) async {
    final t = text.trim();
    if (t.isEmpty) return null;
    final m = ManualTodo('m${DateTime.now().microsecondsSinceEpoch}', t);
    state = TodoEdits(manual: [m, ...state.manual], text: state.text, removed: state.removed);
    await _save();
    return manualKey(m.id);
  }

  /// New wording for [todo]; for a memo's to-do the original comes back
  /// when [text] is the same as the memo's.
  Future<void> edit(Todo todo, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    if (todo.manual) {
      state = TodoEdits(
        manual: [for (final m in state.manual) manualKey(m.id) == todo.key ? ManualTodo(m.id, t) : m],
        text: state.text,
        removed: state.removed,
      );
    } else {
      final original = todo.key.substring(todo.key.indexOf('|') + 1);
      final text2 = {...state.text};
      if (t == original) {
        text2.remove(todo.key);
      } else {
        text2[todo.key] = t;
      }
      state = TodoEdits(manual: state.manual, text: text2, removed: state.removed);
    }
    await _save();
  }

  /// Off the list: a hand-made to-do is deleted, a memo's is hidden (the
  /// memo keeps it).
  Future<void> remove(Todo todo) async {
    if (todo.manual) {
      state = TodoEdits(
        manual: [
          for (final m in state.manual)
            if (manualKey(m.id) != todo.key) m,
        ],
        text: state.text,
        removed: state.removed,
      );
    } else {
      state = TodoEdits(manual: state.manual, text: state.text, removed: {...state.removed, todo.key});
    }
    await _save();
  }

  static String manualKey(String id) => 'manual|$id';
}

final StateNotifierProvider<TodoEditsNotifier, TodoEdits> todoEditsProvider =
    StateNotifierProvider<TodoEditsNotifier, TodoEdits>((ref) => TodoEditsNotifier());

/// The memos' to-dos with the user's changes applied ([withManual]: and the
/// ones added by hand, first).
List<Todo> applyTodoEdits(List<ActionItem> actions, TodoEdits edits, {bool withManual = true}) => [
  if (withManual)
    for (final m in edits.manual) Todo(TodoEditsNotifier.manualKey(m.id), m.text),
  for (final a in actions)
    if (!edits.removed.contains(a.key))
      Todo(a.key, edits.text[a.key] ?? a.text, entry: a.entry, edited: edits.text.containsKey(a.key)),
];

/// Every to-do: added by hand (newest first), then the memos' (newest memo first).
final Provider<List<Todo>> todosProvider = Provider<List<Todo>>((ref) {
  return applyTodoEdits(ref.watch(knowledgeProvider).actions(), ref.watch(todoEditsProvider));
});
