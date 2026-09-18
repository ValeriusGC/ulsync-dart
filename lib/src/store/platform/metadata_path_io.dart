/// IO metadata path: Application Support, not Documents.
///
/// @docImport '../instance_name.dart';
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Resolves `{Application Support}/ulsync/[safeName].db`.
///
/// Support, not Documents: the file holds `source_id`, which must not
/// restore onto a second phone through a documents backup (SPEC section
/// 1.4). The application does not call `path_provider`; this file is the
/// only IO import of that plugin. Engine tests must not call this — they
/// open with `inMemory: true` so VM `flutter test` never hits
/// `MissingPluginException`.
///
/// [safeName] is already validated by [requireInstanceName]; this function
/// does not re-check the character class.
Future<String> resolveMetadataDatabasePath(String safeName) async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory('${support.path}${Platform.pathSeparator}ulsync');
  await dir.create(recursive: true);
  return '${dir.path}${Platform.pathSeparator}$safeName.db';
}
