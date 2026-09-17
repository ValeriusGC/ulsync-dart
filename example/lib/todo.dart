/// Pure to-do domain for the ulsync example (no Flutter imports).
///
/// Rows live in a map keyed by wire id. Trash is [Todo.deleted] == true, not
/// absence: [TodoJournal.listIds] must still name trashed ids, or the library
/// will treat a hidden row as missing and start repairing a loss that did not
/// happen. [Todo.done] and [Todo.deleted] are independent; restoring from
/// trash must not clear the checkbox.
library;

import 'dart:convert';

import 'dart:typed_data';

import 'package:ulsync/ulsync.dart';

/// Wire entity type for every to-do envelope in this example.
///
/// The name is an application choice. The server stores the string opaquely;
/// it is not a protocol reserved word.
const String kTodoEntityType = 'todo';

/// Part name for the done checkbox column in this example.
///
/// Literal chosen by the sample app, not a protocol reserved name. The
/// library forwards the string; only [EntityAdapter.applyPart] interprets it.
const String kTodoPartDone = 'done';

/// Part name for the trash column in this example.
///
/// Hiding a row is a normal part envelope, not a tombstone bit in [Envelope.flags].
const String kTodoPartDeleted = 'deleted';

/// One to-do row in the example journal.
///
/// The row is never removed from the map. Trash is [deleted] == true, not
/// absence: [TodoJournal.listIds] must still name this [id], or the library
/// will treat a hidden row as missing and start repairing a loss that did not
/// happen. [done] and [deleted] are independent; restoring from trash must not
/// clear the checkbox.
final class Todo {
  /// Creates a row. [lastEditedAtMs] defaults to now when omitted.
  Todo({
    required this.id,
    this.title = '',
    this.done = false,
    this.deleted = false,
    int? lastEditedAtMs,
  }) : lastEditedAtMs = lastEditedAtMs ?? DateTime.now().millisecondsSinceEpoch;

  /// Stable wire id; must match the envelope key.
  final String id;

  /// Human-readable text. Only the `full` snapshot writes this field.
  String title;

  /// Checkbox column. Only part [kTodoPartDone] writes this field.
  bool done;

  /// Trash column. Only part [kTodoPartDeleted] writes this field.
  bool deleted;

  /// Latest edit time across title, done, and trash actions on this device.
  ///
  /// Shown in the list and bumped by [TodoJournal.setTitle], [setDone], and
  /// [setDeleted] so a checkbox click moves the timestamp even when the text
  /// did not change.
  int lastEditedAtMs;
}

/// In-memory journal keyed by wire id.
///
/// [listIds] returns every key, including trashed rows, so self-check does not
/// treat trash as data loss. The UI filters [Todo.deleted]; the map does not
/// delete entries.
final class TodoJournal {
  /// Creates an empty journal.
  TodoJournal();

  final Map<String, Todo> _byId = {};

  /// Every stored id, including rows with [Todo.deleted] == true.
  List<String> listIds() => _byId.keys.toList(growable: false);

  /// Active list rows: not in trash, in stable id order for the UI.
  List<Todo> activeTodos() {
    final rows = _byId.values.where((t) => !t.deleted).toList(growable: false)
      ..sort((a, b) => b.lastEditedAtMs.compareTo(a.lastEditedAtMs));
    return rows;
  }

  /// Trash screen rows, newest edit first.
  List<Todo> trashedTodos() {
    final rows = _byId.values.where((t) => t.deleted).toList(growable: false)
      ..sort((a, b) => b.lastEditedAtMs.compareTo(a.lastEditedAtMs));
    return rows;
  }

  /// Ids that are done and not yet trashed — inputs to "Move done to trash".
  List<String> doneNotTrashedIds() => _byId.values
      .where((t) => t.done && !t.deleted)
      .map((t) => t.id)
      .toList(growable: false);

  /// Returns the row for [id], or `null` when this installation never saw it.
  Todo? byId(String id) => _byId[id];

  /// Inserts or replaces title text and bumps [Todo.lastEditedAtMs].
  ///
  /// Creates the row when [id] is new. Does not reset [Todo.done] or
  /// [Todo.deleted]; a full snapshot from the wire must behave the same way
  /// in [EntityAdapter.apply].
  void setTitle(String id, String title) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = _byId[id];
    if (existing == null) {
      _byId[id] = Todo(id: id, title: title, lastEditedAtMs: now);
      return;
    }
    existing.title = title;
    existing.lastEditedAtMs = now;
  }

  /// Applies only the title from an incoming full snapshot.
  ///
  /// Slice fields in the decoded object are ignored so a remote `full` payload
  /// cannot clear [Todo.done] or restore a trashed row by accident.
  void applyFullTitle(String id, String title) {
    final existing = _byId[id];
    if (existing == null) {
      _byId[id] = Todo(id: id, title: title);
      return;
    }
    if (existing.title != title) {
      existing.title = title;
      existing.lastEditedAtMs = DateTime.now().millisecondsSinceEpoch;
    }
  }

  /// Writes the done checkbox and bumps [Todo.lastEditedAtMs].
  void setDone(String id, bool done) {
    final row = _byId.putIfAbsent(id, () => Todo(id: id));
    row.done = done;
    row.lastEditedAtMs = DateTime.now().millisecondsSinceEpoch;
  }

  /// Writes the trash flag and bumps [Todo.lastEditedAtMs].
  ///
  /// Does not clear [Todo.done]; a trashed row may stay done (I5).
  void setDeleted(String id, bool deleted) {
    final row = _byId.putIfAbsent(id, () => Todo(id: id));
    row.deleted = deleted;
    row.lastEditedAtMs = DateTime.now().millisecondsSinceEpoch;
  }

  /// Removes every stored row (for example on sign-out).
  void clear() => _byId.clear();
}

/// Builds the [EntityAdapter] that connects [journal] to [UlsyncClient].
///
/// [onChanged] runs after the journal mutates from sync so the UI can rebuild.
EntityAdapter<Todo> buildTodoAdapter({
  required TodoJournal journal,
  required void Function() onChanged,
}) {
  return EntityAdapter<Todo>(
    entityType: kTodoEntityType,
    schemaVersion: 1,
    listIds: () async => journal.listIds(),
    encode: (todo) => Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object?>{'id': todo.id, 'title': todo.title}),
      ),
    ),
    decode: (bytes, schemaVersion) {
      final decoded = jsonDecode(utf8.decode(bytes));
      final map = Map<String, Object?>.from(decoded as Map);
      return Todo(id: map['id']! as String, title: map['title']! as String);
    },
    load: (id) async => journal.byId(id),
    apply: (todo) async {
      journal.applyFullTitle(todo.id, todo.title);
      onChanged();
    },
    encodePart: (id, part) async {
      final row = journal.byId(id);
      if (row == null) {
        return null;
      }
      return switch (part) {
        kTodoPartDone => _encodeFlag('done', row.done),
        kTodoPartDeleted => _encodeFlag('deleted', row.deleted),
        _ => null,
      };
    },
    applyPart: (id, part, payload) async {
      switch (part) {
        case kTodoPartDone:
          journal.setDone(id, _readFlag(payload, 'done'));
        case kTodoPartDeleted:
          journal.setDeleted(id, _readFlag(payload, 'deleted'));
        default:
          break;
      }
      onChanged();
    },
  );
}

Uint8List _encodeFlag(String key, bool value) {
  return Uint8List.fromList(
    utf8.encode(jsonEncode(<String, bool>{key: value})),
  );
}

bool _readFlag(Uint8List payload, String key) {
  final decoded = jsonDecode(utf8.decode(payload));
  if (decoded is! Map) {
    throw StateError('$key payload is not an object');
  }
  final map = Map<String, Object?>.from(decoded);
  return map[key]! as bool;
}

/// Allowed characters for a device name used in the metadata file name.
final RegExp _safeDevicePattern = RegExp(r'^[A-Za-z0-9._-]+$');

/// File-name fragment for the metadata store. Rejects path traversal.
///
/// Returns `null` when [raw] is empty after trim, contains `..`, or includes
/// characters outside letters, digits, dot, underscore, and hyphen. Two
/// different raw strings must not silently collapse to the same file name.
String? safeDeviceId(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  if (trimmed.contains('..')) {
    return null;
  }
  if (!_safeDevicePattern.hasMatch(trimmed)) {
    return null;
  }
  return trimmed;
}

/// Host and port for the session strip, without scheme or path.
///
/// The UI binds to a server, not to a secret; showing `127.0.0.1:8080` is
/// intentional. Bearer tokens never appear in this string.
String displayHost(Uri baseUrl) {
  if (!baseUrl.hasPort) {
    return baseUrl.host;
  }
  final defaultPort = baseUrl.scheme == 'https' ? 443 : 80;
  if (baseUrl.port == defaultPort) {
    return baseUrl.host;
  }
  return '${baseUrl.host}:${baseUrl.port}';
}

/// Formats [lastEditedAtMs] for a list subtitle in local time.
String formatEditedAtLocal(int lastEditedAtMs) {
  final local = DateTime.fromMillisecondsSinceEpoch(lastEditedAtMs).toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} $h:$m';
}
