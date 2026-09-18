/// Validation for [UlsyncClient.open]'s instance `name`.
///
/// The check lives next to the metadata store, not in the engine, so a bad
/// label fails before any database factory or `path_provider` call.
///
/// @docImport '../engine/sync_engine.dart';
library;

/// Allowed characters for a trimmed instance label.
///
/// Letters, digits, `.`, `_`, and `-`. `..` is rejected separately so a
/// label cannot walk up a directory even though `.` is legal.
final RegExp kInstanceNamePattern = RegExp(r'^[A-Za-z0-9._-]+$');

/// Returns the trimmed instance [name] after checking it is a safe label.
///
/// A name is an installation-local label (`phone`, `tablet`), not a
/// filesystem path and not `origin`. Two processes that share a name share
/// a cursor and a stored `source_id`. The library maps the label to IndexedDB
/// or an Application Support file; the application never passes a path.
///
/// After trim the value must be non-empty, match [kInstanceNamePattern], and
/// must not contain `..`. Otherwise this throws [ArgumentError] before any
/// database is opened and before the network is touched. A path fragment
/// such as `a/b` would otherwise escape the `ulsync/` directory.
String requireInstanceName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(
      name,
      'name',
      'must be a non-empty instance label, not a filesystem path',
    );
  }
  if (trimmed.contains('..')) {
    throw ArgumentError.value(
      name,
      'name',
      'must not contain ".."; it is a label, not a path',
    );
  }
  if (!kInstanceNamePattern.hasMatch(trimmed)) {
    throw ArgumentError.value(
      name,
      'name',
      'must match ${kInstanceNamePattern.pattern}; it is a label, not a path',
    );
  }
  return trimmed;
}
