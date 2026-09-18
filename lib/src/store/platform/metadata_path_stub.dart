/// No metadata location for this target.
///
/// Reached only on a platform that has neither `dart:io` nor JavaScript
/// interop. Throwing beats guessing a cwd file that would vanish on a phone
/// after an update.
library;

/// Always throws [UnsupportedError].
///
/// Tests on the VM and web never reach this file: they use `inMemory: true`
/// or a real IO/web resolver. A guessed cwd path would vanish after an
/// install and would look like a working store.
Future<String> resolveMetadataDatabasePath(String safeName) async {
  throw UnsupportedError(
    'ulsync cannot resolve a metadata path on this platform '
    '(instance "$safeName"). Open the client with inMemory: true in tests, '
    'or run on vm/web.',
  );
}
