import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/ulsync.dart';

import 'json_map.dart';

void main() {
  final minimalPath = 'protocol/fixtures/envelope/minimal.json';
  final nonUtf8Path = 'protocol/fixtures/envelope/non_utf8_payload.json';
  final pushPath = 'protocol/fixtures/push/request_single.json';
  final pullPagePath = 'protocol/fixtures/pull/response_page.json';
  final pullEmptyPath = 'protocol/fixtures/pull/response_empty.json';

  Map<String, Object?> readFixtureMap(String path) {
    final file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'init git submodule: git submodule update --init',
    );
    return decodeJsonMap(file.readAsStringSync());
  }

  test('minimal.json field values match the fixture', () {
    final envelope = Envelope.fromJson(readFixtureMap(minimalPath));

    expect(envelope.id, '3f2504e0-4f89-11d3-9a0c-0305e82c3301');
    expect(envelope.part, 'full');
    expect(envelope.entityType, 'counter_operation');
    expect(envelope.createdAtMs, 1756100000000);
    expect(envelope.lastEditedAtMs, 1756100000000);
    expect(envelope.revision, 1);
    expect(envelope.sourceId, 'device-a');
    expect(envelope.flags, 0);
    expect(envelope.schemaVersion, 1);
    expect(envelope.payloadEncoding, 'json');
    expect(
      envelope.payload,
      Uint8List.fromList(utf8.encode('{"type":"increment"}')),
    );
    expect(envelope.serverSeq, isNull);
  });

  test('round-trip fromJson toJson fromJson preserves equality', () {
    final first = Envelope.fromJson(readFixtureMap(minimalPath));
    final second = Envelope.fromJson(first.toJson());

    expect(second, first);
    expect({first, second}.length, 1);
  });

  test('non_utf8_payload.json payload bytes and exact base64', () {
    final envelope = Envelope.fromJson(readFixtureMap(nonUtf8Path));

    expect(envelope.payload, Uint8List.fromList([0xFF, 0xFE, 0x00, 0x41]));

    final encoded = envelope.toJson()['payload'];
    expect(encoded, '//4AQQ==');

    final urlAlphabet = base64UrlEncode(envelope.payload);
    expect(urlAlphabet, '__4AQQ==');
    expect(encoded, isNot(urlAlphabet));
  });

  test('unknown JSON fields are ignored', () {
    final map = Map<String, Object?>.from(readFixtureMap(minimalPath))
      ..['future_field'] = 'x'
      ..['user_id'] = 'mallory';

    final envelope = Envelope.fromJson(map);

    expect(envelope.id, '3f2504e0-4f89-11d3-9a0c-0305e82c3301');
    expect(envelope.part, 'full');
    expect(envelope.entityType, 'counter_operation');
    expect(envelope.createdAtMs, 1756100000000);
    expect(envelope.lastEditedAtMs, 1756100000000);
    expect(envelope.revision, 1);
    expect(envelope.sourceId, 'device-a');
    expect(envelope.flags, 0);
    expect(envelope.schemaVersion, 1);
    expect(envelope.payloadEncoding, 'json');
    expect(
      envelope.payload,
      Uint8List.fromList(utf8.encode('{"type":"increment"}')),
    );
    expect(envelope.serverSeq, isNull);
  });

  group(
    'missing required field throws UlsyncProtocolException naming the field',
    () {
      const requiredKeys = <String>[
        'id',
        'part',
        'entity_type',
        'created_at_ms',
        'last_edited_at_ms',
        'revision',
        'source_id',
        'flags',
        'schema_version',
        'payload_encoding',
        'payload',
      ];

      for (final key in requiredKeys) {
        test('missing $key', () {
          final map = Map<String, Object?>.from(readFixtureMap(minimalPath))
            ..remove(key);

          expect(
            () => Envelope.fromJson(map),
            throwsA(
              isA<UlsyncProtocolException>()
                  .having((e) => e.field, 'field', key)
                  .having((e) => e.message, 'message', contains(key)),
            ),
          );
        });

        test('null $key', () {
          final map = Map<String, Object?>.from(readFixtureMap(minimalPath))
            ..[key] = null;

          expect(
            () => Envelope.fromJson(map),
            throwsA(
              isA<UlsyncProtocolException>()
                  .having((e) => e.field, 'field', key)
                  .having((e) => e.message, 'message', contains(key)),
            ),
          );
        });
      }
    },
  );

  test('wrong types and undecodable base64 throw UlsyncProtocolException', () {
    final revisionString = Map<String, Object?>.from(
      readFixtureMap(minimalPath),
    )..['revision'] = '1';

    expect(
      () => Envelope.fromJson(revisionString),
      throwsA(
        isA<UlsyncProtocolException>()
            .having((e) => e.field, 'field', 'revision')
            .having((e) => e.message, 'message', contains('revision')),
      ),
    );

    final badBase64 = Map<String, Object?>.from(readFixtureMap(minimalPath))
      ..['payload'] = '%%%';

    expect(
      () => Envelope.fromJson(badBase64),
      throwsA(
        isA<UlsyncProtocolException>()
            .having((e) => e.field, 'field', 'payload')
            .having((e) => e.message, 'message', contains('payload')),
      ),
    );

    final urlAlphabetPayload = Map<String, Object?>.from(
      readFixtureMap(minimalPath),
    )..['payload'] = '__4AQQ==';

    expect(
      () => Envelope.fromJson(urlAlphabetPayload),
      throwsA(
        isA<UlsyncProtocolException>()
            .having((e) => e.field, 'field', 'payload')
            .having((e) => e.message, 'message', contains('payload')),
      ),
    );
  });

  test('absent server_seq is null and omitted from toJson', () {
    final minimal = Envelope.fromJson(readFixtureMap(minimalPath));
    expect(minimal.serverSeq, isNull);
    expect(minimal.toJson().containsKey('server_seq'), isFalse);

    final withSeq = Map<String, Object?>.from(readFixtureMap(minimalPath))
      ..['server_seq'] = 1;
    final pulled = Envelope.fromJson(withSeq);
    expect(pulled.serverSeq, 1);
    expect(pulled.toJson()['server_seq'], 1);

    final nullSeq = Map<String, Object?>.from(readFixtureMap(minimalPath))
      ..['server_seq'] = null;
    final fromNull = Envelope.fromJson(nullSeq);
    expect(fromNull.serverSeq, isNull);
    expect(fromNull.toJson().containsKey('server_seq'), isFalse);
  });

  test(
    'push request and pull page wrappers parse including envelope fields',
    () {
      final push = decodeJsonMap(File(pushPath).readAsStringSync());
      final pushEnvelopes = push['envelopes'];
      expect(pushEnvelopes, isA<List<Object?>>());
      expect(pushEnvelopes, hasLength(1));
      expect(push.containsKey('next_cursor'), isFalse);

      final pushEnvelope = Envelope.fromJson(
        Map<String, Object?>.from((pushEnvelopes! as List).first as Map),
      );
      expect(pushEnvelope.id, '3f2504e0-4f89-11d3-9a0c-0305e82c3301');
      expect(pushEnvelope.serverSeq, isNull);

      final pullPage = decodeJsonMap(File(pullPagePath).readAsStringSync());
      final pullEnvelopes = pullPage['envelopes'];
      expect(pullEnvelopes, isA<List<Object?>>());
      expect(pullEnvelopes, hasLength(1));
      expect(pullPage['next_cursor'], 1);

      final pullEnvelope = Envelope.fromJson(
        Map<String, Object?>.from((pullEnvelopes! as List).first as Map),
      );
      expect(pullEnvelope.serverSeq, 1);

      final pullEmpty = decodeJsonMap(File(pullEmptyPath).readAsStringSync());
      final emptyEnvelopes = pullEmpty['envelopes'];
      expect(emptyEnvelopes, isA<List<Object?>>());
      expect(emptyEnvelopes, isEmpty);
      expect(emptyEnvelopes, isNotNull);
      expect(pullEmpty['next_cursor'], 0);
    },
  );

  test('Envelope.toString does not contain payload base64', () {
    final minimal = Envelope.fromJson(readFixtureMap(minimalPath));
    final nonUtf8 = Envelope.fromJson(readFixtureMap(nonUtf8Path));

    expect(minimal.toString(), isNot(contains('eyJ0eXBlIjoiaW5jcmVtZW50In0=')));
    expect(nonUtf8.toString(), isNot(contains('//4AQQ==')));
  });
}
