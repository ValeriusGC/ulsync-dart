/// IndexedDB store name for one instance.
///
/// The browser has no filesystem path. `sembast_web` already keys by name.
/// This file must not import `path_provider`: that plugin has no web
/// implementation and would force every web build to carry a lie.
///
/// @docImport '../instance_name.dart';
/// @docImport '../../engine/sync_engine.dart';
library;

/// Returns `'ulsync_[safeName]'` for IndexedDB.
///
/// [safeName] is already validated by [requireInstanceName]. The application
/// never sees this string: [UlsyncClient.open] is the only caller.
Future<String> resolveMetadataDatabasePath(String safeName) async {
  return 'ulsync_$safeName';
}
