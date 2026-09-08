/// Two-window tap counter demo for the ulsync client library.
///
/// Connect once per process with a distinct Device ID so each macOS window
/// keeps its own metadata file. Token and base URL defaults come from
/// `--dart-define`; the Connect form can override them before opening
/// [UlsyncClient].
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ulsync/ulsync.dart';
import 'package:ulsync_example/tap.dart';

/// Default origin when `--dart-define=ULSYNC_BASE_URL` is omitted (macOS host).
///
/// Android emulator must pass `http://10.0.2.2:8080` via `--dart-define`; see
/// `example/README.md`.
const String kDefaultBaseUrl = 'http://127.0.0.1:8080';

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
      home: const ExampleHomePage(),
    );
  }
}

/// Connect form and, after a successful handshake, the tap counter screen.
final class ExampleHomePage extends StatefulWidget {
  /// Creates the home page.
  const ExampleHomePage({super.key});

  @override
  State<ExampleHomePage> createState() => _ExampleHomePageState();
}

final class _ExampleHomePageState extends State<ExampleHomePage> {
  /// Compile-time default for the Base URL field.
  static const _defaultBaseUrl = String.fromEnvironment(
    'ULSYNC_BASE_URL',
    defaultValue: kDefaultBaseUrl,
  );

  /// Compile-time default for the Token field (may be empty).
  static const _defaultToken = String.fromEnvironment('ULSYNC_TOKEN');

  /// Compile-time default for the User field.
  static const _defaultUser = String.fromEnvironment(
    'ULSYNC_USER',
    defaultValue: 'alice',
  );

  /// Compile-time default for the Device ID field.
  static const _defaultDeviceId = String.fromEnvironment(
    'ULSYNC_SOURCE_ID',
    defaultValue: 'example-device',
  );

  final _baseUrlController = TextEditingController(text: _defaultBaseUrl);
  final _tokenController = TextEditingController(text: _defaultToken);
  final _userController = TextEditingController(text: _defaultUser);
  final _deviceIdController = TextEditingController(text: _defaultDeviceId);

  /// Local journal; entity payloads are not stored in sembast.
  final TapLog _tapLog = TapLog();

  /// Monotonic tap sequence within this window (part of wire ids).
  int _tapSequence = 0;

  /// Human-readable event lines, newest first.
  final List<String> _events = [];

  UlsyncClient? _client;
  StreamSubscription<SyncEvent>? _liveSub;

  /// Bearer token captured at Connect; survives disposal of the form fields.
  String _connectedToken = '';

  /// Whether the live feed subscription is active.
  bool _liveActive = false;

  /// Per-window network mute; does not call [UlsyncClient.close].
  bool _offline = false;

  bool _connecting = false;
  bool _busy = false;
  String? _formError;

  /// `true` after Connect succeeds; shows the counter instead of the form.
  bool _connected = false;

  @override
  void dispose() {
    unawaited(_liveSub?.cancel());
    unawaited(_client?.close());
    _baseUrlController.dispose();
    _tokenController.dispose();
    _userController.dispose();
    _deviceIdController.dispose();
    super.dispose();
  }

  /// Returns `true` when the Token field has non-whitespace text.
  bool get _tokenPresent => _tokenController.text.trim().isNotEmpty;

  /// Appends one line to the on-screen journal, capped at 20 entries.
  void _log(String line) {
    if (!mounted) {
      return;
    }
    setState(() {
      _events.insert(0, line);
      if (_events.length > 20) {
        _events.removeLast();
      }
    });
  }

  /// Opens the metadata store, client, and live feed using form values.
  Future<void> _connect() async {
    if (_connecting || !_tokenPresent) {
      return;
    }
    setState(() {
      _connecting = true;
      _formError = null;
    });

    final user = _userController.text.trim();
    final deviceRaw = _deviceIdController.text;
    final safeDevice = safeDeviceId(deviceRaw);
    if (safeDevice == null) {
      setState(() {
        _connecting = false;
        _formError =
            'Device ID must use letters, digits, dot, underscore, hyphen '
            'only (no spaces or path segments).';
      });
      return;
    }

    final baseUrlText = _baseUrlController.text.trim();
    final token = _tokenController.text.trim();
    _connectedToken = token;
    _tapLog.clear();
    _tapSequence = 0;

    UlsyncClient? client;
    try {
      final databasePath = kIsWeb
          ? 'ulsync_example_$safeDevice.db'
          : '${(await getApplicationDocumentsDirectory()).path}/'
                'ulsync_example_$safeDevice.db';
      final store = await SembastMetadataStore.open(databasePath: databasePath);
      client = UlsyncClient(
        baseUrl: Uri.parse(baseUrlText),
        userScope: user,
        sourceId: safeDevice,
        tokenProvider: () async =>
            _connectedToken.isEmpty ? null : _connectedToken,
        store: store,
        adapters: [
          EntityAdapter<Tap>(
            entityType: 'counter_operation',
            schemaVersion: 1,
            encode: (tap) => Uint8List.fromList(
              utf8.encode(jsonEncode({'id': tap.id, 'delta': tap.delta})),
            ),
            decode: (bytes, schemaVersion) {
              final decoded = jsonDecode(utf8.decode(bytes));
              final map = Map<String, Object?>.from(decoded as Map);
              return Tap(id: map['id']! as String, delta: map['delta']! as int);
            },
            load: (id) async => _tapLog.byId(id),
            apply: (tap) async {
              final inserted = _tapLog.apply(tap);
              if (inserted && mounted) {
                setState(() {});
              }
            },
          ),
        ],
      );
      _liveSub = client.live().listen(_onLiveEvent, onError: _onLiveError);
      if (!mounted) {
        await client.close();
        return;
      }
      setState(() {
        _client = client;
        _connected = true;
        _offline = false;
        _liveActive = true;
        _connecting = false;
        _events.clear();
      });
      _log('connected');
    } catch (e) {
      await client?.close();
      if (!mounted) {
        return;
      }
      setState(() {
        _connecting = false;
        _formError = '$e';
        _connectedToken = '';
      });
    }
  }

  void _onLiveEvent(SyncEvent event) {
    if (!mounted) {
      return;
    }
    _log(_describe(event));
  }

  void _onLiveError(Object error) {
    if (!mounted) {
      return;
    }
    setState(() {
      _formError = '$error';
    });
    _log('live error: $error');
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

  /// Cancels live, closes the client, and returns to the Connect form.
  Future<void> _disconnect() async {
    await _liveSub?.cancel();
    _liveSub = null;
    await _client?.close();
    if (!mounted) {
      return;
    }
    setState(() {
      _client = null;
      _connected = false;
      _connectedToken = '';
      _liveActive = false;
      _offline = false;
      _tapLog.clear();
      _tapSequence = 0;
    });
  }

  /// Builds the next wire id: device id, UTC micros, and a per-window sequence.
  String _nextTapId(String deviceId) {
    _tapSequence += 1;
    final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return '$deviceId-$micros-$_tapSequence';
  }

  /// Records one plus locally, marks dirty, and syncs when online.
  Future<void> _increment() async {
    final client = _client;
    if (client == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
    });
    try {
      final deviceId = safeDeviceId(_deviceIdController.text)!;
      final tap = Tap(id: _nextTapId(deviceId), delta: 1);
      _tapLog.apply(tap);
      if (mounted) {
        setState(() {});
      }
      await client.markChanged(entityType: 'counter_operation', id: tap.id);
      if (_offline) {
        _log('queued locally (offline)');
      } else {
        final report = await client.syncOnce();
        _log(
          'pushed ${report.pushed}  applied ${report.applied}  '
          'cursor ${report.cursor}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _formError = '$e';
        });
      }
      _log('sync error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  /// Toggles the per-window Offline switch without closing the client.
  Future<void> _setOffline(bool value) async {
    final client = _client;
    if (client == null || _offline == value) {
      return;
    }
    if (value) {
      await _liveSub?.cancel();
      _liveSub = null;
      if (!mounted) {
        return;
      }
      setState(() {
        _offline = true;
        _liveActive = false;
      });
      _log('offline enabled');
      return;
    }

    setState(() {
      _offline = false;
    });
    try {
      final report = await client.syncOnce();
      _log(
        'pushed ${report.pushed}  applied ${report.applied}  '
        'cursor ${report.cursor}',
      );
      _liveSub = client.live().listen(_onLiveEvent, onError: _onLiveError);
      if (!mounted) {
        return;
      }
      setState(() {
        _liveActive = true;
      });
      _log('online restored');
    } catch (e) {
      if (mounted) {
        setState(() {
          _formError = '$e';
        });
      }
      _log('sync error: $e');
    }
  }

  Future<void> _handleDisconnect() async {
    await _disconnect();
    if (!mounted) {
      return;
    }
    setState(() {
      _events.clear();
      _formError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_connected) {
      return _buildCounterScreen(context);
    }
    return _buildConnectScreen(context);
  }

  Widget _buildConnectScreen(BuildContext context) {
    final tokenMissing = !_tokenPresent;
    return Scaffold(
      appBar: AppBar(title: const Text('ulsync example')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: _baseUrlController,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                helperText:
                    'Android emulator uses http://10.0.2.2:8080 '
                    '(pass --dart-define=ULSYNC_BASE_URL=…)',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'Token',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _userController,
              decoration: const InputDecoration(
                labelText: 'User',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _deviceIdController,
              decoration: const InputDecoration(
                labelText: 'Device ID',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            if (tokenMissing)
              const Text(
                'pass a bearer token (local mint: subject alice)',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            if (_formError != null) ...[
              const SizedBox(height: 12),
              Text(_formError!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _connecting || tokenMissing ? null : _connect,
              child: Text(_connecting ? 'Connecting…' : 'Connect'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCounterScreen(BuildContext context) {
    final user = _userController.text.trim();
    final device = safeDeviceId(_deviceIdController.text) ?? '';
    final liveLabel = _liveActive ? 'on' : 'off';
    final offlineLabel = _offline ? 'yes' : 'no';

    return Scaffold(
      appBar: AppBar(
        title: const Text('ulsync example'),
        actions: [
          TextButton(
            onPressed: _handleDisconnect,
            child: const Text('Disconnect'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            Text(
              '${_tapLog.value}',
              style: Theme.of(context).textTheme.displayLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _increment,
              child: const Text('+'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Offline'),
                Switch(value: _offline, onChanged: _setOffline),
              ],
            ),
            Text(
              'user=$user  device=$device  live=$liveLabel  offline=$offlineLabel',
            ),
            if (_formError != null) ...[
              const SizedBox(height: 12),
              Text(_formError!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            Text('Events', style: Theme.of(context).textTheme.titleMedium),
            for (final line in _events) Text('• $line'),
          ],
        ),
      ),
    );
  }
}
