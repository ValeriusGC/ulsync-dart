import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/ulsync.dart';
import 'package:ulsync/src/protocol/sse.dart';

import 'json_map.dart';

void main() {
  test('stream.txt yields envelope, cursor, then heartbeat', () {
    final path = 'protocol/fixtures/live/stream.txt';
    expect(
      File(path).existsSync(),
      isTrue,
      reason: 'init git submodule: git submodule update --init',
    );

    final items = parseLiveFeedLines(File(path).readAsLinesSync());
    expect(items, hasLength(3));

    final envelopeItem = items[0];
    expect(envelopeItem, isA<LiveFeedEvent>());
    final envelopeEvent = envelopeItem as LiveFeedEvent;
    expect(envelopeEvent.name, 'envelope');

    final parsedEnvelope = Envelope.fromJson(decodeJsonMap(envelopeEvent.data));
    expect(parsedEnvelope.serverSeq, 1);

    final cursorItem = items[1];
    expect(cursorItem, isA<LiveFeedEvent>());
    final cursorEvent = cursorItem as LiveFeedEvent;
    expect(cursorEvent.name, 'cursor');

    final cursorData = jsonDecode(cursorEvent.data) as Map<String, Object?>;
    expect(cursorData['next_cursor'], 1);

    expect(items[2], isA<LiveFeedHeartbeat>());
  });

  test(
    'live feed concatenates data lines, empty event name, drops incomplete tail',
    () {
      final multiData = parseLiveFeedLines([
        'event: foo',
        'data: line1',
        'data: line2',
        '',
      ]);
      expect(multiData, hasLength(1));
      final multiEvent = multiData.single as LiveFeedEvent;
      expect(multiEvent.name, 'foo');
      expect(multiEvent.data, 'line1\nline2');

      final unnamed = parseLiveFeedLines(['data: hello', '']);
      expect(unnamed, hasLength(1));
      final unnamedEvent = unnamed.single as LiveFeedEvent;
      expect(unnamedEvent.name, '');
      expect(unnamedEvent.data, 'hello');

      final incomplete = parseLiveFeedLines([
        'event: envelope',
        'data: {incomplete',
      ]);
      expect(incomplete, isEmpty);
    },
  );
}
