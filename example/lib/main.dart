/// Minimal ulsync example: one memo, one button, one live-event list.
///
/// Token and base URL come from `--dart-define`. This app is not an identity
/// provider.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ulsync/ulsync.dart';

/// Stable id for the single memo this example syncs.
const String kMemoId = '11111111-1111-1111-1111-111111111111';

/// Default Android-emulator origin of a local ulsync-server.
const String kDefaultBaseUrl = 'http://10.0.2.2:8080';

void main() {
  runApp(const UlsyncExampleApp());
}

/// Root widget.
final class UlsyncExampleApp extends StatelessWidget {
  /// Creates the example app.
  const UlsyncExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ulsync example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const MemoPage(),
    );
  }
}

/// One-field memo used as the sole synced entity.
///
/// Real applications keep this type in their own database; the in-memory
/// map below exists only so the example stays one file.
final class Memo {
  /// Creates a memo with a stable [id].
  const Memo({required this.id, required this.text});

  /// Wire `id`.
  final String id;

  /// User-visible body.
  final String text;
}

/// Home screen: edit, save-and-sync, watch live events.
final class MemoPage extends StatefulWidget {
  /// Creates the memo screen.
  const MemoPage({super.key});

  @override
  State<MemoPage> createState() => _MemoPageState();
}

final class _MemoPageState extends State<MemoPage> {
  /// Compile-time origin, overridable with `--dart-define=ULSYNC_BASE_URL=`.
  static const _baseUrl = String.fromEnvironment(
    'ULSYNC_BASE_URL',
    defaultValue: kDefaultBaseUrl,
  );

  /// Compile-time bearer token. Empty until `--dart-define=ULSYNC_TOKEN=`.
  static const _token = String.fromEnvironment('ULSYNC_TOKEN');

  /// Compile-time user scope.
  static const _user = String.fromEnvironment(
    'ULSYNC_USER',
    defaultValue: 'alice',
  );

  /// Compile-time installation id.
  static const _sourceId = String.fromEnvironment(
    'ULSYNC_SOURCE_ID',
    defaultValue: 'example-device',
  );

  /// Application store. Upsert by id — that is the idempotent `apply`.
  final Map<String, Memo> _appStore = {};

  final _textController = TextEditingController();
  final _events = <String>[];

  UlsyncClient? _client;
  StreamSubscription<SyncEvent>? _liveSub;
  SyncReport? _report;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_openClient());
  }

  @override
  void dispose() {
    unawaited(_liveSub?.cancel());
    unawaited(_client?.close());
    _textController.dispose();
    super.dispose();
  }

  /// Opens the metadata store and starts the live feed.
  Future<void> _openClient() async {
    try {
      final databasePath = kIsWeb
          ? 'ulsync_example.db'
          : '${(await getApplicationDocumentsDirectory()).path}/ulsync.db';
      final store = await SembastMetadataStore.open(databasePath: databasePath);
      final client = UlsyncClient(
        baseUrl: Uri.parse(_baseUrl),
        userScope: _user,
        sourceId: _sourceId,
        tokenProvider: () async => _token.isEmpty ? null : _token,
        store: store,
        adapters: [
          EntityAdapter<Memo>(
            entityType: 'memo',
            schemaVersion: 1,
            encode: (memo) => Uint8List.fromList(
              utf8.encode(jsonEncode({'id': memo.id, 'text': memo.text})),
            ),
            decode: (bytes, schemaVersion) {
              final decoded = jsonDecode(utf8.decode(bytes));
              final map = Map<String, Object?>.from(decoded as Map);
              return Memo(
                id: map['id']! as String,
                text: map['text']! as String,
              );
            },
            load: (id) async => _appStore[id],
            // Real apps use their own database; upsert by id is the contract.
            apply: (memo) async {
              _appStore[memo.id] = memo;
              if (!mounted) {
                return;
              }
              if (memo.id == kMemoId) {
                _textController.text = memo.text;
              }
            },
          ),
        ],
      );
      _liveSub = client.live().listen(_onEvent, onError: _onLiveError);
      if (!mounted) {
        await client.close();
        return;
      }
      setState(() {
        _client = client;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '$e';
      });
    }
  }

  void _onEvent(SyncEvent event) {
    if (!mounted) {
      return;
    }
    setState(() {
      _events.insert(0, _describe(event));
      if (_events.length > 20) {
        _events.removeLast();
      }
    });
  }

  void _onLiveError(Object error) {
    if (!mounted) {
      return;
    }
    setState(() {
      _error = '$error';
    });
  }

  /// Human-readable line for the on-screen event log.
  String _describe(SyncEvent event) {
    return switch (event) {
      SyncApplied(:final entities) =>
        'applied ${entities.map((e) => '${e.entityType}/${e.id}').join(', ')}',
      SyncCursorAdvanced(:final cursor) => 'cursor $cursor',
      SyncConnectionLost() => 'connection lost',
      SyncConnectionRestored() => 'connection restored',
      SyncUnknownType(:final entityType, :final id) =>
        'unknown type $entityType/$id',
    };
  }

  /// Writes the field into the app store, marks dirty, and runs one sync.
  Future<void> _saveAndSync() async {
    final client = _client;
    if (client == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final memo = Memo(id: kMemoId, text: _textController.text);
      _appStore[kMemoId] = memo;
      await client.markChanged(entityType: 'memo', id: kMemoId);
      final report = await client.syncOnce();
      if (!mounted) {
        return;
      }
      setState(() {
        _report = report;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '$e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokenMissing = _token.isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('ulsync example')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            if (tokenMissing)
              const Text(
                'pass --dart-define=ULSYNC_TOKEN=…',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            Text('base URL: $_baseUrl'),
            Text('user: $_user   source: $_sourceId'),
            const SizedBox(height: 16),
            TextField(
              controller: _textController,
              decoration: const InputDecoration(
                labelText: 'Memo text',
                border: OutlineInputBorder(),
              ),
              minLines: 2,
              maxLines: 4,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _client == null || _busy ? null : _saveAndSync,
              child: Text(_busy ? 'Syncing…' : 'Save and sync'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            if (_report != null) ...[
              const SizedBox(height: 16),
              Text('pushed: ${_report!.pushed}'),
              Text('accepted: ${_report!.accepted}'),
              Text('pulled: ${_report!.pulled}'),
              Text('applied: ${_report!.applied}'),
              Text('cursor: ${_report!.cursor}'),
            ],
            const SizedBox(height: 16),
            Text('Live events', style: Theme.of(context).textTheme.titleMedium),
            for (final line in _events) Text('• $line'),
          ],
        ),
      ),
    );
  }
}
