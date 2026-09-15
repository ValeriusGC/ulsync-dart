/// Self-check: clock preservation, identity, one-shot run, chunking.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:ulsync/ulsync.dart';

import 'fake_diff_transport.dart';
import 'fake_sync_transport.dart';

/// Monotonic suffix so parallel tests never share a database name.
var _pathCounter = 0;

Future<SembastMetadataStore> _openStore() async {
  final factory = databaseFactoryMemory;
  final path = 'self_check_${_pathCounter++}.db';
  await factory.deleteDatabase(path);
  final store = await SembastMetadataStore.open(
    databasePath: path,
    factory: factory,
  );
  addTearDown(() async {
    await store.close();
    await factory.deleteDatabase(path);
  });
  return store;
}

final class _Memo {
  const _Memo({required this.id, required this.text});

  final String id;
  final String text;
}

Uint8List _memoBytes({required String id, required String text}) {
  return Uint8List.fromList(utf8.encode(jsonEncode({'id': id, 'text': text})));
}

_Memo _memoFrom(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  final map = Map<String, Object?>.from(decoded as Map);
  return _Memo(id: map['id']! as String, text: map['text']! as String);
}

EntityAdapter<_Memo> _adapter({
  required Map<String, String> appStore,
  Future<List<String>> Function()? listIds,
  int Function()? onListIds,
}) {
  final enumerate = listIds;
  return EntityAdapter<_Memo>(
    entityType: 'note',
    schemaVersion: 1,
    encode: (memo) => _memoBytes(id: memo.id, text: memo.text),
    decode: (bytes, schemaVersion) => _memoFrom(bytes),
    load: (id) async {
      final text = appStore[id];
      if (text == null) {
        return null;
      }
      return _Memo(id: id, text: text);
    },
    apply: (memo) async {
      appStore[memo.id] = memo.text;
    },
    listIds: enumerate == null
        ? null
        : () async {
            onListIds?.call();
            return enumerate();
          },
  );
}

UlsyncClient _client({
  required SembastMetadataStore store,
  required SyncTransport transport,
  required EntityAdapter<_Memo> adapter,
  String userScope = 'alice',
  String sourceId = 'device-a',
}) {
  final client = UlsyncClient(
    baseUrl: Uri.parse('http://self-check.test'),
    userScope: userScope,
    sourceId: sourceId,
    tokenProvider: () async => 'test-token',
    store: store,
    adapters: [adapter],
    transport: transport,
  );
  addTearDown(client.close);
  return client;
}

EntityState _row({
  String userScope = 'alice',
  String id = 'e1',
  int createdAtMs = 1_000,
  int lastEditedAtMs = 2_000,
  int revision = 4,
  bool dirty = false,
  String sourceId = 'device-a',
}) {
  return EntityState(
    userScope: userScope,
    entityType: 'note',
    id: id,
    part: 'full',
    createdAtMs: createdAtMs,
    lastEditedAtMs: lastEditedAtMs,
    revision: revision,
    sourceId: sourceId,
    schemaVersion: 1,
    dirty: dirty,
  );
}

void main() {
  test('adapter without listIds reports local unavailable and syncOnce still '
      'pushes', () async {
    final store = await _openStore();
    final fake = FakeSyncTransport();
    final appStore = <String, String>{'e1': 'hello'};
    final client = _client(
      store: store,
      transport: fake,
      adapter: _adapter(appStore: appStore),
    );
    final check = await client.selfCheck();
    expect(check.localAvailable, isFalse);
    expect(check.localMarked, 0);
    expect(check.serverAvailable, isFalse);
    expect(fake.pushCalls, isEmpty);
    expect(fake.pullCalls, isEmpty);
    await client.markChanged(entityType: 'note', id: 'e1');
    final report = await client.syncOnce();
    expect(report.pushed, 1);
    expect(fake.pushCalls, hasLength(1));
  });

  test('unknown application id is marked with time 1 and revision 1', () async {
    final store = await _openStore();
    final fake = FakeDiffTransport();
    final appStore = <String, String>{'e1': 'hello'};
    final client = _client(
      store: store,
      transport: fake,
      adapter: _adapter(appStore: appStore, listIds: () async => ['e1']),
    );
    final check = await client.selfCheck();
    expect(check.localAvailable, isTrue);
    expect(check.localMarked, 1);
    expect(fake.pushCalls, hasLength(1));
    final envelope = fake.pushCalls.single.single;
    expect(envelope.id, 'e1');
    expect(envelope.lastEditedAtMs, 1);
    expect(envelope.createdAtMs, 1);
    expect(envelope.revision, 1);
  });

  test(
    'missing server key is marked without changing the conflict clock',
    () async {
      final store = await _openStore();
      final before = _row(
        createdAtMs: 1_111,
        lastEditedAtMs: 2_222,
        revision: 7,
      );
      await store.put(before);
      final fake = FakeDiffTransport();
      fake.onDiff = (probes) async => [
        DiffVerdict(id: 'e1', part: 'full', gap: DiffGap.missing),
      ];
      final appStore = <String, String>{'e1': 'hello'};
      final client = _client(
        store: store,
        transport: fake,
        adapter: _adapter(appStore: appStore),
      );
      final check = await client.selfCheck();
      expect(check.serverAvailable, isTrue);
      expect(check.serverMissing, 1);
      expect(check.serverStale, 0);
      final after = await store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'e1',
        part: 'full',
      );
      expect(after!.lastEditedAtMs, before.lastEditedAtMs);
      expect(after.createdAtMs, before.createdAtMs);
      expect(after.revision, before.revision);
      expect(after.sourceId, before.sourceId);
      expect(fake.pushCalls, hasLength(1));
      final envelope = fake.pushCalls.single.single;
      expect(envelope.lastEditedAtMs, 2_222);
      expect(envelope.createdAtMs, 1_111);
      expect(envelope.revision, 7);
    },
  );

  test(
    'stale server key is marked without changing the conflict clock',
    () async {
      final store = await _openStore();
      final before = _row(
        createdAtMs: 5_000,
        lastEditedAtMs: 9_000,
        revision: 3,
      );
      await store.put(before);
      final fake = FakeDiffTransport();
      fake.onDiff = (probes) async => [
        const DiffVerdict(
          id: 'e1',
          part: 'full',
          gap: DiffGap.stale,
          serverLastEditedAtMs: 1_000,
          serverRevision: 9,
          serverSourceId: 'device-b',
        ),
      ];
      final appStore = <String, String>{'e1': 'hello'};
      final client = _client(
        store: store,
        transport: fake,
        adapter: _adapter(appStore: appStore),
      );
      await client.selfCheck();
      final after = await store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'e1',
        part: 'full',
      );
      expect(after!.lastEditedAtMs, 9_000);
      expect(after.createdAtMs, 5_000);
      expect(after.revision, 3);
      expect(fake.pushCalls.single.single.lastEditedAtMs, 9_000);
      expect(fake.pushCalls.single.single.revision, 3);
    },
  );

  test(
    'diff probe carries all three ranks from metadata without loss',
    () async {
      final store = await _openStore();
      await store.put(
        _row(lastEditedAtMs: 1756100000000, revision: 3, sourceId: 'device-a'),
      );
      final fake = FakeDiffTransport();
      List<DiffProbe>? seen;
      fake.onDiff = (probes) async {
        seen = List<DiffProbe>.from(probes);
        return const [];
      };
      final client = _client(
        store: store,
        transport: fake,
        adapter: _adapter(appStore: {}),
      );
      await client.selfCheck();
      expect(seen, isNotNull);
      expect(seen, hasLength(1));
      expect(seen!.single.id, 'e1');
      expect(seen!.single.part, 'full');
      expect(seen!.single.lastEditedAtMs, 1756100000000);
      expect(seen!.single.revision, 3);
      expect(seen!.single.sourceId, 'device-a');
    },
  );

  test(
    'diff returning null makes the server phase unavailable without throwing',
    () async {
      final store = await _openStore();
      await store.put(_row());
      final fake = FakeDiffTransport();
      fake.onDiff = (probes) async => null;
      final client = _client(
        store: store,
        transport: fake,
        adapter: _adapter(appStore: {'e1': 'hello'}),
      );
      final check = await client.selfCheck();
      expect(check.serverAvailable, isFalse);
      expect(check.serverMarked, 0);
      expect(fake.pushCalls, isEmpty);
      final report = await client.syncOnce();
      expect(report.pushed, 0);
    },
  );

  test('transport without SyncDiffTransport skips the server phase', () async {
    final store = await _openStore();
    await store.put(_row());
    final fake = FakeSyncTransport();
    final client = _client(
      store: store,
      transport: fake,
      adapter: _adapter(appStore: {}),
    );
    final check = await client.selfCheck();
    expect(check.serverAvailable, isFalse);
    expect(fake.pushCalls, isEmpty);
    expect(fake.pullCalls, isEmpty);
  });

  test('includeServer false runs local and does not call diff', () async {
    var listCalls = 0;
    final store = await _openStore();
    final fake = FakeDiffTransport();
    final appStore = <String, String>{'e1': 'hello'};
    final client = _client(
      store: store,
      transport: fake,
      adapter: _adapter(
        appStore: appStore,
        listIds: () async => ['e1'],
        onListIds: () => listCalls++,
      ),
    );
    final check = await client.selfCheck(includeServer: false);
    expect(check.localAvailable, isTrue);
    expect(check.localMarked, 1);
    expect(check.serverAvailable, isFalse);
    expect(fake.diffCalls, isEmpty);
    expect(listCalls, 1);
  });

  test(
    'first open stores source_id; a second open with the same id succeeds',
    () async {
      final store = await _openStore();
      final fake = FakeSyncTransport();
      final client = _client(
        store: store,
        transport: fake,
        adapter: _adapter(appStore: {}),
      );
      expect(await store.readSourceId('alice'), isNull);
      await client.selfCheck(includeServer: false);
      expect(await store.readSourceId('alice'), 'device-a');
      await client.selfCheck(includeServer: false);
      expect(await store.readSourceId('alice'), 'device-a');
    },
  );

  test(
    'changed source_id throws StateError naming both values and repeats',
    () async {
      final store = await _openStore();
      final first = _client(
        store: store,
        transport: FakeSyncTransport(),
        adapter: _adapter(appStore: {}),
      );
      await first.selfCheck(includeServer: false);
      final second = UlsyncClient(
        baseUrl: Uri.parse('http://self-check.test'),
        userScope: 'alice',
        sourceId: 'device-b',
        tokenProvider: () async => 'test-token',
        store: store,
        adapters: [_adapter(appStore: {})],
        transport: FakeSyncTransport(),
      );
      Future<void> expectIdentityError(Future<void> Function() call) async {
        await expectLater(
          call(),
          throwsA(
            isA<StateError>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('device-a'), contains('device-b')),
            ),
          ),
        );
      }

      await expectIdentityError(second.syncOnce);
      await expectIdentityError(second.syncOnce);
    },
  );

  test(
    'self-check on first syncOnce runs listIds and diff only once',
    () async {
      var listCalls = 0;
      final store = await _openStore();
      await store.put(_row());
      final fake = FakeDiffTransport();
      final client = _client(
        store: store,
        transport: fake,
        adapter: _adapter(
          appStore: {'e1': 'hello'},
          listIds: () async => ['e1'],
          onListIds: () => listCalls++,
        ),
      );
      await client.syncOnce();
      await client.syncOnce();
      expect(listCalls, 1);
      expect(fake.diffCalls, hasLength(1));
    },
  );

  test('failed first syncOnce retries self-check on the next call', () async {
    var listCalls = 0;
    var pulls = 0;
    final store = await _openStore();
    await store.put(_row());
    final fake = FakeDiffTransport();
    fake.onPull = ({required int since, int? limit}) async {
      pulls++;
      if (pulls == 1) {
        throw const UlsyncNetworkException('offline');
      }
      return PullPage(envelopes: const [], nextCursor: since);
    };
    final client = _client(
      store: store,
      transport: fake,
      adapter: _adapter(
        appStore: {'e1': 'hello'},
        listIds: () async => ['e1'],
        onListIds: () => listCalls++,
      ),
    );
    await expectLater(
      client.syncOnce(),
      throwsA(isA<UlsyncNetworkException>()),
    );
    expect(listCalls, 1);
    await client.syncOnce();
    expect(listCalls, 2);
    expect(fake.diffCalls, hasLength(2));
  });

  test('501 known records are probed in batches of 500 and 1', () async {
    final store = await _openStore();
    for (var i = 0; i < 501; i++) {
      await store.put(_row(id: 'e$i', lastEditedAtMs: i, revision: 1));
    }
    final fake = FakeDiffTransport();
    final client = _client(
      store: store,
      transport: fake,
      adapter: _adapter(appStore: {}),
    );
    final check = await client.selfCheck();
    expect(check.serverAvailable, isTrue);
    expect(check.serverProbed, 501);
    expect(fake.diffCalls, hasLength(2));
    expect(fake.diffCalls[0], hasLength(500));
    expect(fake.diffCalls[1], hasLength(1));
  });

  test('selfCheck completes without deadlocking on the serial lock', () async {
    final store = await _openStore();
    await store.put(_row());
    final fake = FakeDiffTransport();
    final appStore = <String, String>{'e1': 'hello'};
    final client = _client(
      store: store,
      transport: fake,
      adapter: _adapter(appStore: appStore, listIds: () async => ['e1']),
    );
    final check = await client.selfCheck();
    expect(check.remainingDirty, 0);
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('records of another userScope are not enumerated or probed', () async {
    final store = await _openStore();
    await store.put(_row(id: 'alice-row', lastEditedAtMs: 10));
    await store.put(
      _row(userScope: 'bob', id: 'bob-row', lastEditedAtMs: 99, revision: 8),
    );
    final fake = FakeDiffTransport();
    List<DiffProbe>? seen;
    fake.onDiff = (probes) async {
      seen = List<DiffProbe>.from(probes);
      return const [];
    };
    final client = _client(
      store: store,
      transport: fake,
      adapter: _adapter(appStore: {}),
    );
    await client.selfCheck();
    expect(seen, isNotNull);
    expect(seen!.map((p) => p.id), ['alice-row']);
    expect(await store.allStates('alice').then((s) => s.map((e) => e.id)), [
      'alice-row',
    ]);
  });
}
