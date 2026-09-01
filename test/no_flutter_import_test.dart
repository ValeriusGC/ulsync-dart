/// Fails if any Dart file under `lib/src/protocol/` imports Flutter.
///
/// The protocol codec (later steps) must stay pure Dart so it runs in
/// `flutter test` without a device. Editors often insert `package:flutter/`
/// or `dart:ui` on auto-complete. A missing directory is not a failure:
/// this step must not add stub files; zero files means zero violations.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('protocol core does not import package:flutter or dart:ui', () {
    final dir = Directory('lib/src/protocol');
    if (!dir.existsSync()) {
      return;
    }

    final forbidden = <String>[];
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final lines = File(entity.path).readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trimLeft();
        if (trimmed.startsWith('//')) {
          continue;
        }
        if (_isForbiddenImport(trimmed)) {
          forbidden.add('${entity.path}:${i + 1}: ${lines[i]}');
        }
      }
    }

    expect(forbidden, isEmpty, reason: forbidden.join('\n'));
  });
}

/// True when [line] is an import or export of Flutter or `dart:ui`.
bool _isForbiddenImport(String line) {
  if (!line.startsWith('import ') && !line.startsWith('export ')) {
    return false;
  }
  return line.contains('package:flutter/') ||
      line.contains("dart:ui'") ||
      line.contains('dart:ui"');
}
