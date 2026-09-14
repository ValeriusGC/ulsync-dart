/// Protocol fixtures for SPEC section 3.4 parsed by the transport types.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/ulsync.dart';

import 'json_map.dart';

/// Reason when the protocol submodule was not initialized.
const _submoduleHint = 'git submodule update --init';

String _fixture(String relative) {
  final path = 'protocol/fixtures/$relative';
  expect(File(path).existsSync(), isTrue, reason: _submoduleHint);
  return File(path).readAsStringSync();
}

List<DiffProbe> _probes(String relative) {
  final map = decodeJsonMap(_fixture(relative));
  final raw = map['items']! as List<dynamic>;
  return [
    for (final item in raw)
      DiffProbe.fromJson(Map<String, Object?>.from(item as Map)),
  ];
}

List<DiffVerdict> _verdicts(String relative) {
  final map = decodeJsonMap(_fixture(relative));
  final missing = map['missing']! as List<dynamic>;
  final stale = map['stale']! as List<dynamic>;
  return [
    for (final item in missing)
      DiffVerdict.fromJson(
        Map<String, Object?>.from(item as Map),
        DiffGap.missing,
      ),
    for (final item in stale)
      DiffVerdict.fromJson(
        Map<String, Object?>.from(item as Map),
        DiffGap.stale,
      ),
  ];
}

void main() {
  test('diff request.json round-trips without losing fields', () {
    final first = _probes('diff/request.json');
    expect(first, hasLength(4));
    expect(first[0].id, '3f2504e0-4f89-11d3-9a0c-0305e82c3301');
    expect(first[0].lastEditedAtMs, 1756100000000);
    expect(first[0].revision, 1);
    expect(first[0].sourceId, 'device-a');
    expect(first[2].revision, 3);
    expect(first[3].revision, 1);
    final encoded = jsonEncode({
      'items': first.map((p) => p.toJson()).toList(),
    });
    final second = [
      for (final item in decodeJsonMap(encoded)['items']! as List<dynamic>)
        DiffProbe.fromJson(Map<String, Object?>.from(item as Map)),
    ];
    expect(second, first);
  });

  test('diff response_gaps.json round-trips missing and stale ranks', () {
    final first = _verdicts('diff/response_gaps.json');
    expect(first, hasLength(3));
    expect(first[0].gap, DiffGap.missing);
    expect(first[0].serverLastEditedAtMs, isNull);
    expect(first[1].gap, DiffGap.stale);
    expect(first[1].serverLastEditedAtMs, 1756000000000);
    expect(first[1].serverRevision, 3);
    expect(first[1].serverSourceId, 'device-b');
    expect(first[2].serverRevision, 5);
    final encoded = jsonEncode({
      'missing': [
        for (final v in first.where((v) => v.gap == DiffGap.missing))
          v.toJson(),
      ],
      'stale': [
        for (final v in first.where((v) => v.gap == DiffGap.stale)) v.toJson(),
      ],
    });
    final map = decodeJsonMap(encoded);
    final second = [
      for (final item in map['missing']! as List<dynamic>)
        DiffVerdict.fromJson(
          Map<String, Object?>.from(item as Map),
          DiffGap.missing,
        ),
      for (final item in map['stale']! as List<dynamic>)
        DiffVerdict.fromJson(
          Map<String, Object?>.from(item as Map),
          DiffGap.stale,
        ),
    ];
    expect(second, first);
  });

  test('diff request_tie.json round-trips the three-rank tie', () {
    final first = _probes('diff/request_tie.json');
    expect(first, hasLength(1));
    expect(first.single.id, '3f2504e0-4f89-11d3-9a0c-0305e82c3301');
    expect(first.single.lastEditedAtMs, 1756100000000);
    expect(first.single.revision, 1);
    expect(first.single.sourceId, 'device-a');
    final encoded = jsonEncode({
      'items': first.map((p) => p.toJson()).toList(),
    });
    final second = [
      for (final item in decodeJsonMap(encoded)['items']! as List<dynamic>)
        DiffProbe.fromJson(Map<String, Object?>.from(item as Map)),
    ];
    expect(second, first);
  });
}
