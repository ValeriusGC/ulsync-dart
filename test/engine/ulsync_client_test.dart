/// Engine tests against a fake transport and an in-memory sembast store.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:ulsync/src/store/sembast_metadata_store.dart';
import 'package:ulsync/ulsync.dart';

import 'fake_sync_transport.dart';

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
  String entityType = 'note',
  int createdAtMs = 1000,
}) {
  return Envelope(
    id: id,
    part: 'full',
    entityType: entityType,
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

/// Holds one client, its store, fake transport, and in-memory app records.
final class _Harness {
  /// Creates a harness. Prefer [_Harness.open].
  _Harness({
    required this.store,
    required this.fake,
    required this.client,
    required this.appStore,
    required this.applyCount,
  });

  /// Real sembast metadata store (in memory).
  final SembastMetadataStore store;

  /// Scripted transport.
  final FakeSyncTransport fake;

  /// Client under test.
  final UlsyncClient client;

  /// Application records keyed by id. [EntityAdapter.apply] upserts here.
  final Map<String, String> appStore;

  /// Times [EntityAdapter.apply] ran. A one-element list so apply closures
  /// can increment it without capturing an unassigned [_Harness].
  final List<int> applyCount;

  /// Apply calls observed so far.
  int get applies => applyCount.first;

  /// Opens a client with a note adapter and an injected fake transport.
  static Future<_Harness> open({
    Future<void> Function()? beforePersistIncoming,
    Completer<void>? applyGate,
    void Function()? onApplyEntered,
  }) async {
    final factory = databaseFactoryMemory;
    final name = 'engine_test_${_pathCounter++}';
    await factory.deleteDatabase(name);
    final fake = FakeSyncTransport();
    final appStore = <String, String>{};
    final applyCount = <int>[0];
    final client = await UlsyncClient.open(
      name: name,
      baseUrl: Uri.parse('http://engine.test'),
      origin: 'com.example.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f',
      userScope: 'alice',
      sourceId: 'device-a',
      tokenProvider: () async => 'test-token',
      adapters: [
        EntityAdapter<_Memo>(
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
            onApplyEntered?.call();
            if (applyGate != null) {
              await applyGate.future;
            }
            applyCount[0]++;
            appStore[memo.id] = memo.text;
          },
          listIds: () async => appStore.keys.toList(growable: false),
        ),
      ],
      transport: fake,
      inMemory: true,
      beforePersistIncoming: beforePersistIncoming,
    );
    final store = await SembastMetadataStore.open(
      databasePath: name,
      factory: factory,
    );
    final harness = _Harness(
      store: store,
      fake: fake,
      client: client,
      appStore: appStore,
      applyCount: applyCount,
    );
    addTearDown(() async {
      await harness.client.close();
      await factory.deleteDatabase(name);
    });
    return harness;
  }
}

/// Yields the event loop until [condition] is true, at most [max] times.
Future<void> _pumpUntil(bool Function() condition, {int max = 50}) async {
  for (var i = 0; i < max; i++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition not met after $max event-loop yields');
}

/// Whether the engine cursor, as [SyncTransport.live] would read it, is [cursor].
///
/// [EntityAdapter.apply] finishing is not enough: in-memory cursor moves only
/// after metadata persist, and that await yields. Reconnect tests that wait
/// on apply count race here under randomized package-wide order.
bool _memoryCursorIs(_Harness h, int cursor) {
  final read = h.fake.appliedSince;
  return read != null && read() == cursor;
}

void main() {
  test(
    'markChanged on a new entity sets revision 1 and dirty; a second call sets 2',
    () async {
      final h = await _Harness.open();
      await h.client.markChanged(entityType: 'note', id: 'e1');
      final first = await h.store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'e1',
        part: 'full',
      );
      expect(first, isNotNull);
      expect(first!.revision, 1);
      expect(first.dirty, isTrue);
      await h.client.markChanged(entityType: 'note', id: 'e1');
      final second = await h.store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'e1',
        part: 'full',
      );
      expect(second!.revision, 2);
      expect(second.dirty, isTrue);
    },
  );

  test(
    'syncOnce pushes a dirty entity and clears dirty; report.pushed is 1',
    () async {
      final h = await _Harness.open();
      h.appStore['e1'] = 'hello';
      await h.client.markChanged(entityType: 'note', id: 'e1');
      final report = await h.client.syncOnce();
      expect(report.pushed, 1);
      expect(report.accepted, 1);
      expect(h.fake.pushCalls, hasLength(1));
      final after = await h.store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'e1',
        part: 'full',
      );
      expect(after!.dirty, isFalse);
      expect(await h.store.dirtyBatch(userScope: 'alice', limit: 50), isEmpty);
    },
  );

  test(
    'applied false clears dirty and a second syncOnce pushes nothing',
    () async {
      final h = await _Harness.open();
      h.appStore['e1'] = 'hello';
      await h.client.markChanged(entityType: 'note', id: 'e1');
      h.fake.onPush = (envelopes) async => [
        PushResult(id: envelopes.single.id, part: 'full', applied: false),
      ];
      h.fake.onPull = ({required int since, int? limit}) async {
        return PullPage(envelopes: const [], nextCursor: 0);
      };
      final report = await h.client.syncOnce();
      expect(report.pushed, 1);
      expect(report.accepted, 0);
      expect(await h.store.dirtyBatch(userScope: 'alice', limit: 50), isEmpty);
      final state = await h.store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'e1',
        part: 'full',
      );
      expect(state!.dirty, isFalse);
      await h.client.syncOnce();
      expect(h.fake.pushCalls, hasLength(1));
    },
  );

  test('load returning null clears dirty without calling push', () async {
    final h = await _Harness.open();
    await h.client.markChanged(entityType: 'note', id: 'e1');
    expect(h.appStore.containsKey('e1'), isFalse);
    final report = await h.client.syncOnce();
    expect(report.pushed, 0);
    expect(h.fake.pushCalls, isEmpty);
    expect(await h.store.dirtyBatch(userScope: 'alice', limit: 50), isEmpty);
  });

  test(
    'pull applies an envelope, writes metadata, and advances the cursor',
    () async {
      final h = await _Harness.open();
      h.fake.onPull = ({required int since, int? limit}) async {
        if (since == 0) {
          return PullPage(
            envelopes: [
              _memoEnvelope(id: 'e1', serverSeq: 7, text: 'from-server'),
            ],
            nextCursor: 7,
          );
        }
        return PullPage(envelopes: const [], nextCursor: since);
      };
      final report = await h.client.syncOnce();
      expect(h.applies, 1);
      expect(h.appStore['e1'], 'from-server');
      expect(report.pulled, 1);
      expect(report.applied, 1);
      expect(report.cursor, 7);
      expect(await h.store.readCursor('alice'), 7);
      final state = await h.store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'e1',
        part: 'full',
      );
      expect(state, isNotNull);
      expect(state!.revision, 2);
      expect(state.dirty, isFalse);
    },
  );

  test(
    'incoming older is skipped; newer is applied; sourceId breaks remaining ties',
    () async {
      Future<void> runCase({
        required String id,
        required int challengerTime,
        required int challengerRev,
        required String challengerSource,
        required bool expectApply,
        required String expectedText,
      }) async {
        final h = await _Harness.open();
        h.fake.onPull = ({required int since, int? limit}) async {
          if (since == 0) {
            return PullPage(
              envelopes: [
                _memoEnvelope(
                  id: id,
                  serverSeq: 1,
                  text: 'local',
                  lastEditedAtMs: 1000,
                  revision: 2,
                  sourceId: 'device-a',
                ),
              ],
              nextCursor: 1,
            );
          }
          if (since == 1) {
            return PullPage(
              envelopes: [
                _memoEnvelope(
                  id: id,
                  serverSeq: 2,
                  text: 'challenger',
                  lastEditedAtMs: challengerTime,
                  revision: challengerRev,
                  sourceId: challengerSource,
                ),
              ],
              nextCursor: 2,
            );
          }
          return PullPage(envelopes: const [], nextCursor: since);
        };
        await h.client.syncOnce();
        expect(h.applies, 1);
        expect(h.appStore[id], 'local');
        await h.client.syncOnce();
        expect(h.applies, expectApply ? 2 : 1);
        expect(h.appStore[id], expectedText);
        expect(await h.store.readCursor('alice'), 2);
      }

      await runCase(
        id: 'e-older',
        challengerTime: 500,
        challengerRev: 9,
        challengerSource: 'zzzz',
        expectApply: false,
        expectedText: 'local',
      );
      await runCase(
        id: 'e-newer',
        challengerTime: 2000,
        challengerRev: 1,
        challengerSource: 'aaaa',
        expectApply: true,
        expectedText: 'challenger',
      );
      await runCase(
        id: 'e-rev',
        challengerTime: 1000,
        challengerRev: 3,
        challengerSource: 'aaaa',
        expectApply: true,
        expectedText: 'challenger',
      );
      await runCase(
        id: 'e-src-win',
        challengerTime: 1000,
        challengerRev: 2,
        challengerSource: 'device-b',
        expectApply: true,
        expectedText: 'challenger',
      );
      await runCase(
        id: 'e-src-lose',
        challengerTime: 1000,
        challengerRev: 2,
        challengerSource: 'device-0',
        expectApply: false,
        expectedText: 'local',
      );
    },
  );

  test(
    'a full pull page triggers a second pull; a short page does not',
    () async {
      final full = await _Harness.open();
      full.fake.onPull = ({required int since, int? limit}) async {
        if (since == 0) {
          return PullPage(
            envelopes: [
              for (var i = 1; i <= 100; i++)
                _memoEnvelope(
                  id: 'n$i',
                  serverSeq: i,
                  text: 't$i',
                  lastEditedAtMs: 1000 + i,
                  revision: 1,
                ),
            ],
            nextCursor: 100,
          );
        }
        return PullPage(envelopes: const [], nextCursor: 100);
      };
      await full.client.syncOnce();
      expect(full.fake.pullCalls, hasLength(2));
      expect(full.fake.pullCalls[0].limit, 100);

      final short = await _Harness.open();
      short.fake.onPull = ({required int since, int? limit}) async {
        return PullPage(
          envelopes: [
            for (var i = 1; i <= 3; i++)
              _memoEnvelope(id: 's$i', serverSeq: i, text: 't$i'),
          ],
          nextCursor: 3,
        );
      };
      await short.client.syncOnce();
      expect(short.fake.pullCalls, hasLength(1));
    },
  );

  test('a live cursor behind the applied cursor is ignored', () async {
    final h = await _Harness.open();
    h.fake.onPull = ({required int since, int? limit}) async {
      return PullPage(envelopes: const [], nextCursor: since == 0 ? 50 : since);
    };
    await h.client.syncOnce();
    expect(await h.store.readCursor('alice'), 50);
    final events = <SyncEvent>[];
    h.client.live().listen(events.add);
    await _pumpUntil(() => h.fake.appliedSince != null);
    h.fake.liveController.add(const LiveCursor(10));
    for (var i = 0; i < 16; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(await h.store.readCursor('alice'), 50);
    expect(events.whereType<SyncCursorAdvanced>(), isEmpty);
    h.fake.onPull = ({required int since, int? limit}) async {
      if (since == 0) {
        return PullPage(envelopes: const [], nextCursor: 50);
      }
      return PullPage(envelopes: const [], nextCursor: since);
    };
    final report = await h.client.syncOnce();
    expect(report.cursor, 50);
    expect(await h.store.readCursor('alice'), 50);
  });

  test('push response does not move the cursor', () async {
    final h = await _Harness.open();
    h.appStore['e1'] = 'hello';
    await h.client.markChanged(entityType: 'note', id: 'e1');
    h.fake.onPull = ({required int since, int? limit}) async {
      return PullPage(envelopes: const [], nextCursor: 0);
    };
    final report = await h.client.syncOnce();
    expect(report.pushed, 1);
    expect(report.cursor, 0);
    expect(await h.store.readCursor('alice'), 0);
  });

  test(
    'apply runs again after a crash between apply and metadata persist',
    () async {
      var persistCalls = 0;
      final h = await _Harness.open(
        beforePersistIncoming: () async {
          persistCalls++;
          if (persistCalls == 1) {
            throw StateError('simulated crash');
          }
        },
      );
      h.fake.onPull = ({required int since, int? limit}) async {
        if (since == 0) {
          return PullPage(
            envelopes: [_memoEnvelope(id: 'e1', serverSeq: 5, text: 'hello')],
            nextCursor: 5,
          );
        }
        return PullPage(envelopes: const [], nextCursor: since);
      };
      await expectLater(h.client.syncOnce(), throwsA(isA<StateError>()));
      expect(h.applies, 1);
      expect(await h.store.readCursor('alice'), 0);
      expect(h.appStore['e1'], 'hello');
      final report = await h.client.syncOnce();
      expect(h.applies, 2);
      expect(report.cursor, 5);
      expect(await h.store.readCursor('alice'), 5);
    },
  );

  test(
    'live applies envelopes, advances the cursor, and emits SyncApplied',
    () async {
      final h = await _Harness.open();
      final events = <SyncEvent>[];
      h.client.live().listen(events.add);
      await _pumpUntil(() => h.fake.appliedSince != null);
      h.fake.liveController.add(
        LiveEnvelope(_memoEnvelope(id: 'e1', serverSeq: 3, text: 'live')),
      );
      await _pumpUntil(() => _memoryCursorIs(h, 3));
      expect(h.appStore['e1'], 'live');
      expect(await h.store.readCursor('alice'), 3);
      expect(events.whereType<SyncApplied>(), isNotEmpty);
      expect(events.whereType<SyncCursorAdvanced>(), isNotEmpty);
    },
  );

  test('syncOnce and live apply never overlap', () async {
    final applyGate = Completer<void>();
    var applyEntered = false;
    var pullEntered = false;
    var overlap = 0;
    final h = await _Harness.open(
      applyGate: applyGate,
      onApplyEntered: () {
        applyEntered = true;
      },
    );
    h.fake.onBeforePull = () {
      pullEntered = true;
      if (!applyGate.isCompleted) {
        overlap++;
      }
    };
    h.client.live().listen((_) {});
    await _pumpUntil(() => h.fake.appliedSince != null);
    h.fake.liveController.add(
      LiveEnvelope(_memoEnvelope(id: 'e1', serverSeq: 1, text: 'live')),
    );
    await _pumpUntil(() => applyEntered);
    final pending = h.client.syncOnce();
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(pullEntered, isFalse);
    expect(overlap, 0);
    applyGate.complete();
    await pending;
    expect(overlap, 0);
  });

  test(
    'reconnect reads the applied cursor, not the cursor from live start',
    () async {
      final h = await _Harness.open();
      h.client.live().listen((_) {});
      await _pumpUntil(() => h.fake.appliedSince != null);
      expect(h.fake.appliedSinceReads, [0]);
      h.fake.liveController.add(
        LiveEnvelope(_memoEnvelope(id: 'e1', serverSeq: 8, text: 'live')),
      );
      await _pumpUntil(() => _memoryCursorIs(h, 8));
      h.fake.simulateReconnect();
      expect(h.fake.appliedSinceReads, [0, 8]);
    },
  );

  test(
    'close closes transport and store; later calls throw StateError',
    () async {
      final h = await _Harness.open();
      await h.client.close();
      expect(h.fake.closed, isTrue);
      expect(() => h.client.live(), throwsA(isA<StateError>()));
      expect(
        () => h.client.markChanged(entityType: 'note', id: 'e1'),
        throwsA(isA<StateError>()),
      );
      expect(() => h.client.syncOnce(), throwsA(isA<StateError>()));
      await h.client.close();
    },
  );

  test('live still opens when pull fails because the server is down', () async {
    final h = await _Harness.open();
    await h.store.writeCursor('alice', 18, 1000);
    h.fake.onPull = ({required int since, int? limit}) async {
      throw const UlsyncNetworkException('server down');
    };
    Object? liveError;
    h.client.live().listen(
      (_) {},
      onError: (Object e, StackTrace _) {
        liveError = e;
      },
    );
    await _pumpUntil(() => h.fake.appliedSince != null);
    expect(liveError, isNull);
    expect(h.fake.appliedSinceReads, isNotEmpty);
  });

  test(
    'syncOnce replays from since=0 when local cursor is ahead of server feed',
    () async {
      final h = await _Harness.open();
      await h.store.writeCursor('alice', 18, 1000);
      h.fake.onPull = ({required int since, int? limit}) async {
        if (since == 0) {
          return PullPage(
            envelopes: [
              for (var i = 1; i <= 9; i++)
                _memoEnvelope(id: 'e$i', serverSeq: i, text: 't$i'),
            ],
            nextCursor: 9,
          );
        }
        return PullPage(envelopes: const [], nextCursor: since);
      };
      final report = await h.client.syncOnce();
      expect(h.applies, 9);
      expect(report.applied, 9);
      expect(report.cursor, 9);
      expect(await h.store.readCursor('alice'), 9);
      expect(h.fake.pullCalls.where((call) => call.since == 0), hasLength(2));
    },
  );

  test(
    'unknown entityType skips apply, advances cursor, and emits SyncUnknownType',
    () async {
      final h = await _Harness.open();
      final events = <SyncEvent>[];
      h.client.live().listen(events.add);
      await _pumpUntil(() => h.fake.appliedSince != null);
      h.fake.onPull = ({required int since, int? limit}) async {
        if (since == 0) {
          return PullPage(
            envelopes: [
              _memoEnvelope(
                id: 'x1',
                serverSeq: 4,
                text: 'nope',
                entityType: 'no_such_type',
              ),
            ],
            nextCursor: 4,
          );
        }
        return PullPage(envelopes: const [], nextCursor: since);
      };
      await h.client.syncOnce();
      await Future<void>.delayed(Duration.zero);
      expect(h.applies, 0);
      expect(await h.store.readCursor('alice'), 4);
      expect(events.whereType<SyncUnknownType>(), isNotEmpty);
      expect(
        events.whereType<SyncUnknownType>().first.entityType,
        'no_such_type',
      );
    },
  );

  test('write marks the record dirty before persist runs', () async {
    final h = await _Harness.open();
    var persistSawDirty = false;
    await h.client.write<void>(
      entityType: 'note',
      id: 'e1',
      persist: () async {
        final state = await h.store.stateOf(
          userScope: 'alice',
          entityType: 'note',
          id: 'e1',
          part: 'full',
        );
        expect(state, isNotNull);
        expect(state!.dirty, isTrue);
        persistSawDirty = true;
        h.appStore['e1'] = 'hello';
      },
    );
    expect(persistSawDirty, isTrue);
  });

  test('write returns the persist callback result', () async {
    final h = await _Harness.open();
    final value = await h.client.write<int>(
      entityType: 'note',
      id: 'e1',
      persist: () async {
        h.appStore['e1'] = 'hello';
        return 42;
      },
    );
    expect(value, 42);
  });

  test(
    'persist throw keeps the dirty mark; later syncOnce sends nothing and clears it',
    () async {
      final h = await _Harness.open();
      await expectLater(
        h.client.write<void>(
          entityType: 'note',
          id: 'e1',
          persist: () async {
            throw StateError('persist failed');
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'persist failed',
          ),
        ),
      );
      final afterThrow = await h.store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'e1',
        part: 'full',
      );
      expect(afterThrow, isNotNull);
      expect(afterThrow!.dirty, isTrue);
      expect(h.appStore.containsKey('e1'), isFalse);
      final report = await h.client.syncOnce();
      expect(report.pushed, 0);
      expect(h.fake.pushCalls, isEmpty);
      final afterSync = await h.store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'e1',
        part: 'full',
      );
      expect(afterSync!.dirty, isFalse);
    },
  );

  test(
    'syncOnce inside persist throws StateError instead of deadlocking',
    () async {
      final h = await _Harness.open();
      await expectLater(
        h.client
            .write<void>(
              entityType: 'note',
              id: 'e1',
              persist: () async {
                await h.client.syncOnce();
              },
            )
            .timeout(const Duration(seconds: 2)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('persist callback'),
          ),
        ),
      );
    },
  );

  test(
    'markChanged inside persist throws StateError instead of deadlocking',
    () async {
      final h = await _Harness.open();
      await expectLater(
        h.client
            .write<void>(
              entityType: 'note',
              id: 'e1',
              persist: () async {
                await h.client.markChanged(entityType: 'note', id: 'e1');
              },
            )
            .timeout(const Duration(seconds: 2)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('persist callback'),
          ),
        ),
      );
    },
  );

  test(
    'nested write inside persist throws StateError instead of deadlocking',
    () async {
      final h = await _Harness.open();
      var innerPersistRan = false;
      await expectLater(
        h.client
            .write<void>(
              entityType: 'note',
              id: 'e1',
              persist: () async {
                await h.client.write<void>(
                  entityType: 'note',
                  id: 'e2',
                  persist: () async {
                    innerPersistRan = true;
                  },
                );
              },
            )
            .timeout(const Duration(seconds: 2)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('persist callback'),
          ),
        ),
      );
      expect(innerPersistRan, isFalse);
    },
  );

  test(
    'write with an unknown entityType throws ArgumentError and does not touch the store',
    () async {
      final h = await _Harness.open();
      var persistRan = false;
      await expectLater(
        h.client.write<void>(
          entityType: 'no_such_type',
          id: 'e1',
          persist: () async {
            persistRan = true;
          },
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(persistRan, isFalse);
      expect(
        await h.store.stateOf(
          userScope: 'alice',
          entityType: 'no_such_type',
          id: 'e1',
          part: 'full',
        ),
        isNull,
      );
    },
  );

  test('write after close throws StateError', () async {
    final h = await _Harness.open();
    await h.client.close();
    var persistRan = false;
    expect(
      () => h.client.write<void>(
        entityType: 'note',
        id: 'e1',
        persist: () async {
          persistRan = true;
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('UlsyncClient is closed'),
        ),
      ),
    );
    expect(persistRan, isFalse);
  });

  test(
    'write and concurrent syncOnce push the persisted payload once',
    () async {
      final h = await _Harness.open();
      final persistEntered = Completer<void>();
      final persistHold = Completer<void>();
      var pushWhilePersistHeld = false;
      h.fake.onBeforePush = () {
        if (!persistHold.isCompleted) {
          pushWhilePersistHeld = true;
        }
      };
      final writeFuture = h.client.write<void>(
        entityType: 'note',
        id: 'e1',
        persist: () async {
          persistEntered.complete();
          await persistHold.future;
          h.appStore['e1'] = 'from-write';
        },
      );
      await persistEntered.future;
      final syncFuture = h.client.syncOnce();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(h.fake.pushCalls, isEmpty);
      expect(pushWhilePersistHeld, isFalse);
      persistHold.complete();
      await writeFuture;
      await syncFuture;
      expect(h.fake.pushCalls, hasLength(1));
      expect(h.fake.pushCalls.single, hasLength(1));
      final envelope = h.fake.pushCalls.single.single;
      expect(envelope.id, 'e1');
      expect(_memoFrom(envelope.payload).text, 'from-write');
      expect(pushWhilePersistHeld, isFalse);
    },
  );
}
