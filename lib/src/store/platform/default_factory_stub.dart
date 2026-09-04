import 'package:sembast/sembast.dart';

/// No built-in implementation for this target.
///
/// Reached only on a platform that has neither `dart:io` nor JavaScript
/// interop. Throwing beats guessing: the message names the way out.
DatabaseFactory get defaultDatabaseFactory => throw UnsupportedError(
  'ulsync has no built-in storage implementation for this platform. '
  'Pass factory: to SembastMetadataStore.open explicitly.',
);
