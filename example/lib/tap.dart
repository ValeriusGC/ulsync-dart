/// Pure tap journal for the ulsync example (no Flutter imports).
///
/// Each plus button appends one [Tap] with a unique [Tap.id]. The on-screen
/// total is the sum of [Tap.delta] values, not a single synced integer.
library;

/// One increment. Immutable. Wire id is [id]; [delta] is always 1 in the UI.
final class Tap {
  /// Creates a tap record.
  const Tap({required this.id, required this.delta});

  /// Stable wire id; must match the envelope key.
  final String id;

  /// Increment amount. The UI always sends `1`; tests may use other values.
  final int delta;
}

/// In-memory log. The on-screen total is the sum of [Tap.delta].
///
/// Two windows both increment by writing *different* ids, so last-write-wins
/// on a single entity never drops a click. The server stores records; it
/// does not add numbers.
final class TapLog {
  /// Creates an empty journal.
  TapLog();

  final Map<String, Tap> _byId = {};

  /// Sum of all stored [Tap.delta] values.
  int get value => _byId.values.fold<int>(0, (sum, t) => sum + t.delta);

  /// Returns the tap for [id], or `null` when this installation never saw it.
  Tap? byId(String id) => _byId[id];

  /// Inserts [tap] when [tap.id] is new.
  ///
  /// Returns `true` when [tap] was inserted. A duplicate [Tap.id] is a no-op
  /// and returns `false` so live replay does not double the counter.
  bool apply(Tap tap) {
    if (_byId.containsKey(tap.id)) {
      return false;
    }
    _byId[tap.id] = tap;
    return true;
  }

  /// Removes every stored tap (for example when reconnecting another device).
  void clear() => _byId.clear();
}

/// Allowed characters for a device id used in the metadata file name.
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
