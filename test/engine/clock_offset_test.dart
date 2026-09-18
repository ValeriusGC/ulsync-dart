/// Frozen store-clock offset tests. Names are literal: `accept_38.sh` greps them.
///
/// Engine tests open the client only with `inMemory: true` so
/// `path_provider` is never loaded on the VM. [UlsyncClient.open] `nowMs`
/// is the test hatch; these cases never move the OS clock.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:ulsync/src/engine/lww.dart';
import 'package:ulsync/src/store/entity_state.dart';
import 'package:ulsync/src/store/sembast_metadata_store.dart';
import 'package:ulsync/ulsync.dart';

import 'fake_hello_transport.dart';
import 'fake_sync_transport.dart';

/// Two days in milliseconds, the product skew used in the frozen cases.
const _skewMs = 2 * 86400000;

/// Monotonic suffix so parallel tests never share a database name.
var _pathCounter = 0;

/// Test entity: id plus text so [EntityAdapter.apply] can upsert by id.
final class _Memo {
  /// Creates a memo with a stable [id].
  const _Memo({required this.id, required this.text});

  /// Wire `id`.
  final String id;

  /// Application payload text.
  final String text;
}

/// JSON payload bytes for [_Memo], including [id] so decode can rebuild it.
Uint8List _memoBytes({required String id, required String text}) {
  return Uint8List.fromList(utf8.encode(jsonEncode({'id': id, 'text': text})));
}

/// Rebuilds a [_Memo] from [_memoBytes].
_Memo _memoFrom(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) {
    throw StateError('memo payload is not an object');
  }
  final map = Map<String, Object?>.from(decoded);
  return _Memo(id: map['id']! as String, text: map['text']! as String);
}

/// Incoming envelope used by pull and live tests.
Envelope _memoEnvelope({
  required String id,
  required int serverSeq,
  required String text,
  int lastEditedAtMs = 1000,
  int revision = 2,
  String sourceId = 'device-a',
  int createdAtMs = 1000,
}) {
  return Envelope(
    id: id,
    part: 'full',
    entityType: 'note',
    createdAtMs: createdAtMs,
    lastEditedAtMs: lastEditedAtMs,
    revision: revision,
    sourceId: sourceId,
    flags: 0,
    schemaVersion: 1,
    payloadEncoding: 'json',
    payload: _memoBytes(id: id, text: text),
    serverSeq: serverSeq,
  );
}

/// Shared in-memory store used by two [FakeHelloTransport] clients.
final class _Warehouse {
  int _seq = 0;
  final Map<String, Envelope> _rows = {};
  final List<FakeHelloTransport> _clients = [];

  /// Wires [fake] so both clients share one last-write-wins map.
  void bind(FakeHelloTransport fake) {
    _clients.add(fake);
    fake.onPush = (envelopes) async {
      final results = <PushResult>[];
      for (final envelope in envelopes) {
        _seq++;
        final key = '${envelope.id}\u0000${envelope.part}';
        final existing = _rows[key];
        final applied =
            existing == null ||
            incomingWins(
              incomingLastEditedAtMs: envelope.lastEditedAtMs,
              incomingRevision: envelope.revision,
              incomingSourceId: envelope.sourceId,
              localLastEditedAtMs: existing.lastEditedAtMs,
              localRevision: existing.revision,
              localSourceId: existing.sourceId,
            );
        if (applied) {
          final stored = Envelope(
            id: envelope.id,
            part: envelope.part,
            entityType: envelope.entityType,
            createdAtMs: envelope.createdAtMs,
            lastEditedAtMs: envelope.lastEditedAtMs,
            revision: envelope.revision,
            sourceId: envelope.sourceId,
            flags: envelope.flags,
            schemaVersion: envelope.schemaVersion,
            payloadEncoding: envelope.payloadEncoding,
            payload: envelope.payload,
            serverSeq: _seq,
          );
          _rows[key] = stored;
          for (final other in _clients) {
            if (identical(other, fake) ||
                other.closed ||
                other.liveController.isClosed) {
              continue;
            }
            other.liveController.add(LiveEnvelope(stored));
          }
        }
        results.add(
          PushResult(id: envelope.id, part: envelope.part, applied: applied),
        );
      }
      return results;
    };
    fake.onPull = ({required int since, int? limit}) async {
      final listed =
          _rows.values
              .where((envelope) => (envelope.serverSeq ?? 0) > since)
              .toList()
            ..sort((a, b) => (a.serverSeq ?? 0).compareTo(b.serverSeq ?? 0));
      final take = limit == null ? listed : listed.take(limit).toList();
      final next = take.isEmpty ? since : take.last.serverSeq!;
      return PullPage(
        envelopes: take,
        nextCursor: next,
        serverNowMs: fake.serverNowMs,
      );
    };
  }
}

/// Note client, in-memory domain, and an injected transport.
final class _Harness {
  /// Creates a harness. Prefer [_Harness.open].
  _Harness({
    required this.name,
    required this.store,
    required this.transport,
    required this.client,
    required this.appStore,
  });

  /// In-memory database name, reused across close/open of the same instance.
  final String name;

  /// Real sembast metadata store (in memory).
  final SembastMetadataStore store;

  /// Scripted transport. No HTTP.
  final SyncTransport transport;

  /// Client under test.
  final UlsyncClient client;

  /// Application records keyed by id.
  final Map<String, String> appStore;

  /// Opens a note client with [transport] and optional injected [nowMs].
  static Future<_Harness> open({
    required SyncTransport transport,
    String? name,
    String sourceId = 'device-a',
    Map<String, String>? appStore,
    bool deleteExisting = true,
    int Function()? nowMs,
  }) async {
    final factory = databaseFactoryMemory;
    final path = name ?? 'clock_offset_${_pathCounter++}';
    if (deleteExisting) {
      await factory.deleteDatabase(path);
    }
    final domain = appStore ?? <String, String>{};
    final client = await UlsyncClient.open(
      name: path,
      baseUrl: Uri.parse('http://engine.test'),
      origin: 'com.example.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f',
      userScope: 'alice',
      sourceId: sourceId,
      tokenProvider: () async => 'test-token',
      adapters: [
        EntityAdapter<_Memo>(
          entityType: 'note',
          schemaVersion: 1,
          encode: (memo) => _memoBytes(id: memo.id, text: memo.text),
          decode: (bytes, schemaVersion) => _memoFrom(bytes),
          load: (id) async {
            final text = domain[id];
            if (text == null) {
              return null;
            }
            return _Memo(id: id, text: text);
          },
          apply: (memo, meta) async {
            domain[memo.id] = memo.text;
          },
          listIds: () async => domain.keys.toList(growable: false),
        ),
      ],
      transport: transport,
      inMemory: true,
      catchUpRetryDelay: Duration.zero,
      nowMs: nowMs,
    );
    final store = await SembastMetadataStore.open(
      databasePath: path,
      factory: factory,
    );
    addTearDown(() async {
      await client.close();
      await store.close();
    });
    return _Harness(
      name: path,
      store: store,
      transport: transport,
      client: client,
      appStore: domain,
    );
  }

  /// Metadata row for [id], or `null`.
  Future<EntityState?> stateOf(String id, {String part = 'full'}) {
    return store.stateOf(
      userScope: 'alice',
      entityType: 'note',
      id: id,
      part: part,
    );
  }

  /// Push batches recorded by the fake, if it is one of the engine doubles.
  List<List<Envelope>> get pushCalls {
    final candidate = transport;
    if (candidate is FakeHelloTransport) {
      return candidate.pushCalls;
    }
    if (candidate is FakeSyncTransport) {
      return candidate.pushCalls;
    }
    throw StateError('transport does not record push');
  }

  /// Starts [UlsyncClient.live] and waits until the fake captured callbacks.
  Future<void> startLive() async {
    client.live().listen((_) {});
    await _pumpUntil(() {
      final candidate = transport;
      if (candidate is FakeHelloTransport) {
        return candidate.appliedSince != null;
      }
      if (candidate is FakeSyncTransport) {
        return candidate.appliedSince != null;
      }
      return false;
    });
  }

  /// Persists [text] for [id] through [UlsyncClient.write].
  Future<void> writeNote(String id, String text) {
    return client.write<void>(
      entityType: 'note',
      id: id,
      persist: () async {
        appStore[id] = text;
      },
    );
  }
}

Future<void> _pumpUntil(bool Function() condition, {int max = 200}) async {
  for (var i = 0; i < max; i++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition not met after $max event-loop yields');
}

void main() {
  test('write before any server sample stamps raw nowMs', () async {
    final fake = FakeSyncTransport();
    final h = await _Harness.open(transport: fake, nowMs: () => 1000);
    await h.writeNote('e1', 'raw');
    final state = await h.stateOf('e1');
    expect(state, isNotNull);
    expect(state!.lastEditedAtMs, 1000);
    expect(state.createdAtMs, 1000);
    expect(fake.pushCalls, isEmpty);
  });

  test('hello sample: subsequent write stamps nowMs plus offset', () async {
    const raw = 1000 + _skewMs;
    final fake = FakeHelloTransport()..serverNowMs = 1000;
    final h = await _Harness.open(transport: fake, nowMs: () => raw);
    await h.client.syncOnce();
    await h.writeNote('e1', 'corrected');
    final state = await h.stateOf('e1');
    expect(state, isNotNull);
    expect(state!.lastEditedAtMs, 1000);
    expect(state.createdAtMs, 1000);
  });

  test(
    'skewed device does not overwrite a fresher edit after both sampled server time',
    () async {
      const base = 1_700_000_000_000;
      final warehouse = _Warehouse();
      var bNow = base;
      final aFake = FakeHelloTransport()..serverNowMs = base;
      final bFake = FakeHelloTransport()..serverNowMs = base;
      final a = await _Harness.open(
        transport: aFake,
        sourceId: 'device-a',
        nowMs: () => base + _skewMs,
      );
      final b = await _Harness.open(
        transport: bFake,
        sourceId: 'device-b',
        nowMs: () => bNow,
      );
      warehouse.bind(aFake);
      warehouse.bind(bFake);
      await a.startLive();
      await b.startLive();
      await a.writeNote('e1', 'first');
      bNow = base + 5;
      await b.writeNote('e1', 'second');
      await _pumpUntil(
        () => a.appStore['e1'] == 'second' && b.appStore['e1'] == 'second',
        max: 400,
      );
      expect(a.appStore['e1'], 'second');
      expect(b.appStore['e1'], 'second');
      expect(a.appStore['e1'], isNot(contains('firstsecond')));
      expect(b.appStore['e1'], isNot(contains('firstsecond')));
    },
  );

  test('first sample rewrites dirty lastEditedAt of this sourceId', () async {
    const raw = 1000 + _skewMs;
    final fake = FakeHelloTransport()..serverNowMs = 1000;
    final h = await _Harness.open(transport: fake, nowMs: () => raw);
    await h.writeNote('mine', 'local');
    await h.store.put(
      EntityState(
        userScope: 'alice',
        entityType: 'note',
        id: 'foreign',
        part: 'full',
        createdAtMs: 50,
        lastEditedAtMs: 50,
        revision: 1,
        sourceId: 'device-other',
        schemaVersion: 1,
        dirty: true,
      ),
    );
    fake.onPull = ({required int since, int? limit}) async {
      return PullPage(
        envelopes: [
          _memoEnvelope(
            id: 'incoming',
            serverSeq: 1,
            text: 'wire',
            lastEditedAtMs: 50,
            createdAtMs: 50,
            sourceId: 'device-other',
          ),
        ],
        nextCursor: 1,
        serverNowMs: 1000,
      );
    };
    await h.client.syncOnce();
    final local = await h.stateOf('mine');
    expect(local, isNotNull);
    expect(local!.lastEditedAtMs, 1000);
    expect(local.createdAtMs, 1000);
    expect(local.sourceId, 'device-a');
    final foreign = await h.stateOf('foreign');
    expect(foreign, isNotNull);
    expect(foreign!.lastEditedAtMs, 50);
    expect(foreign.createdAtMs, 50);
    expect(foreign.sourceId, 'device-other');
    final incoming = await h.stateOf('incoming');
    expect(incoming, isNotNull);
    expect(incoming!.lastEditedAtMs, 50);
  });

  test('incoming lastEditedAt is not rewritten by local offset', () async {
    const raw = 1000 + _skewMs;
    final fake = FakeHelloTransport()..serverNowMs = 1000;
    fake.onPull = ({required int since, int? limit}) async {
      return PullPage(
        envelopes: [
          _memoEnvelope(
            id: 'e1',
            serverSeq: 1,
            text: 'from-wire',
            lastEditedAtMs: 50,
            createdAtMs: 50,
            sourceId: 'device-other',
          ),
        ],
        nextCursor: 1,
        serverNowMs: 1000,
      );
    };
    final h = await _Harness.open(transport: fake, nowMs: () => raw);
    await h.client.syncOnce();
    final state = await h.stateOf('e1');
    expect(state, isNotNull);
    expect(state!.lastEditedAtMs, 50);
    expect(state.createdAtMs, 50);
    expect(state.sourceId, 'device-other');
  });

  test('cursor advances when lastEditedAt is far in the future', () async {
    final futureMs = DateTime.utc(2090, 1, 1).millisecondsSinceEpoch;
    final fake = FakeSyncTransport();
    fake.onPull = ({required int since, int? limit}) async {
      if (since >= 9) {
        return PullPage(envelopes: const [], nextCursor: 9);
      }
      return PullPage(
        envelopes: [
          _memoEnvelope(
            id: 'e1',
            serverSeq: 9,
            text: 'future',
            lastEditedAtMs: futureMs,
            createdAtMs: futureMs,
          ),
        ],
        nextCursor: 9,
      );
    };
    final h = await _Harness.open(transport: fake, nowMs: () => 1000);
    await h.client.syncOnce();
    expect(await h.store.readCursor('alice'), 9);
    expect(h.appStore['e1'], 'future');
  });

  test('missing server_now_ms does not fail hello', () async {
    final fake = FakeHelloTransport();
    fake.onHello = (origin) async {
      return HelloResult(origin: origin, userId: 'alice');
    };
    final h = await _Harness.open(transport: fake, nowMs: () => 5000);
    await h.client.syncOnce();
    await h.writeNote('e1', 'raw-after-hello');
    final state = await h.stateOf('e1');
    expect(state, isNotNull);
    expect(state!.lastEditedAtMs, 5000);
    expect(fake.helloCalls, hasLength(1));
  });

  test(
    'reopen same inMemory name: writes before next hello use persisted offset',
    () async {
      const raw = 1000 + _skewMs;
      final name = 'clock_reopen_${_pathCounter++}';
      final appStore = <String, String>{};
      final firstFake = FakeHelloTransport()..serverNowMs = 1000;
      final first = await _Harness.open(
        transport: firstFake,
        name: name,
        appStore: appStore,
        nowMs: () => raw,
      );
      await first.client.syncOnce();
      await first.client.close();
      await first.store.close();

      final secondFake = FakeSyncTransport();
      final second = await _Harness.open(
        transport: secondFake,
        name: name,
        appStore: appStore,
        deleteExisting: false,
        nowMs: () => raw,
      );
      await second.writeNote('e1', 'persisted-offset');
      final state = await second.stateOf('e1');
      expect(state, isNotNull);
      expect(state!.lastEditedAtMs, 1000);
      expect(secondFake.pushCalls, isEmpty);
    },
  );

  test(
    'live running: write after sample drains without the test calling syncOnce',
    () async {
      final fake = FakeHelloTransport()..serverNowMs = 1000;
      final h = await _Harness.open(transport: fake, nowMs: () => 1000);
      await h.startLive();
      await h.writeNote('e1', 'drained');
      await _pumpUntil(() => h.pushCalls.isNotEmpty);
      expect(h.pushCalls.single.single.id, 'e1');
      expect(h.pushCalls.single.single.lastEditedAtMs, 1000);
    },
  );
}
