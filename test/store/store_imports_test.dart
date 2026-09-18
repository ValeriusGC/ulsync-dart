@TestOn('vm')
/// Guards import rules for the metadata store tree.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Platform-specific sembast imports are allowed only in these files.
const _allowedSembastIo = 'lib/src/store/platform/default_factory_io.dart';

/// Browser sembast imports are allowed only in this file.
const _allowedSembastWeb = 'lib/src/store/platform/default_factory_web.dart';

/// `dart:io` and `path_provider` are allowed only in the IO name resolver.
const _allowedPathProvider = 'lib/src/store/platform/metadata_path_io.dart';

void main() {
  test('lib/ obeys store import boundaries', () {
    final libDir = Directory('lib');
    expect(
      libDir.existsSync(),
      isTrue,
      reason: 'lib/ must exist once the store step lands',
    );
    final storeDir = Directory('lib/src/store');
    expect(
      storeDir.existsSync(),
      isTrue,
      reason: 'lib/src/store/ is required for step 12',
    );

    final forbidden = <String>[];
    final sembastIoHits = <String>[];
    final sembastWebHits = <String>[];
    final dartIoHits = <String>[];
    final pathProviderHits = <String>[];

    for (final entity in libDir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final path = entity.path.replaceAll(r'\', '/');
      final lines = entity.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trimLeft();
        if (trimmed.startsWith('//')) {
          continue;
        }
        if (_isForbidden(trimmed)) {
          forbidden.add('$path:${i + 1}: ${lines[i]}');
        }
        if (trimmed.contains('sembast_io')) {
          sembastIoHits.add(path);
        }
        if (trimmed.contains('sembast_web')) {
          sembastWebHits.add(path);
        }
        if (trimmed.contains("dart:io'") || trimmed.contains('dart:io"')) {
          dartIoHits.add(path);
        }
        if (trimmed.contains('package:path_provider/')) {
          pathProviderHits.add(path);
        }
      }
    }

    expect(forbidden, isEmpty, reason: forbidden.join('\n'));
    expect(sembastIoHits.toSet(), {
      _allowedSembastIo,
    }, reason: sembastIoHits.join('\n'));
    expect(sembastWebHits.toSet(), {
      _allowedSembastWeb,
    }, reason: sembastWebHits.join('\n'));
    expect(dartIoHits.toSet(), {
      _allowedPathProvider,
    }, reason: dartIoHits.join('\n'));
    expect(pathProviderHits.toSet(), {
      _allowedPathProvider,
    }, reason: pathProviderHits.join('\n'));

    final platformDir = Directory('lib/src/store/platform');
    expect(
      platformDir.listSync().whereType<File>().length,
      8,
      reason: 'platform/ holds four factory files and four name-resolver files',
    );
  });
}

/// True when [line] imports a forbidden platform or Flutter library.
///
/// `dart:io` and `path_provider` are allowed only in
/// `metadata_path_io.dart` and are counted separately.
bool _isForbidden(String line) {
  if (!line.startsWith('import ') && !line.startsWith('export ')) {
    return false;
  }
  return line.contains('package:flutter/') ||
      line.contains("dart:ui'") ||
      line.contains('dart:ui"');
}
