/// Self-hosted to-do list demo for the ulsync client library.
///
/// Each to-do is an **indivisible, complete** kit: `full` (title), `done`,
/// and `deleted`. Pair once per process with a distinct device name so
/// each macOS window keeps its own metadata file. Server address and
/// access key may be prefilled from `--dart-define`; pairing still walks
/// health and whoami before [UlsyncClient] opens.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ulsync/ulsync.dart';
import 'package:ulsync_example/server_probe.dart';
import 'package:ulsync_example/session_status.dart';
import 'package:ulsync_example/todo.dart';

/// Default origin when `--dart-define=ULSYNC_BASE_URL` is omitted (macOS host).
const String kDefaultBaseUrl = 'http://127.0.0.1:8080';

/// Application-contour origin (SPEC section 1.5). Same string on every
/// installation of this example; never minted per device.
const String kUlsyncOrigin =
    'com.example.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f';

void main() {
  runApp(const TodosApp());
}

/// Root widget for the round-2 living client sample.
final class TodosApp extends StatelessWidget {
  /// Creates the example application.
  const TodosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Todos',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const TodosRootPage(),
    );
  }
}

/// Pairing gate and, after sign-in, the synchronized to-do screens.
final class TodosRootPage extends StatefulWidget {
  /// Creates the root page.
  const TodosRootPage({super.key});

  @override
  State<TodosRootPage> createState() => _TodosRootPageState();
}

enum _PairingStep { serverAddress, signIn, signedIn }

/// Pairing and signed-in UI. Forwards process wake to the engine.
///
/// [UlsyncClient] cannot import Flutter. This state is the
/// `WidgetsBindingObserver` that calls [UlsyncClient.notifyResumed] on
/// `AppLifecycleState.resumed` so a half-open live socket is dropped
/// immediately after sleep.
final class _TodosRootPageState extends State<TodosRootPage>
    with WidgetsBindingObserver {
  static const _defaultServer = String.fromEnvironment(
    'ULSYNC_BASE_URL',
    defaultValue: kDefaultBaseUrl,
  );

  static const _defaultAccessKey = String.fromEnvironment('ULSYNC_TOKEN');

  static const _defaultDeviceName = String.fromEnvironment(
    'ULSYNC_SOURCE_ID',
    defaultValue: 'phone',
  );

  final _serverController = TextEditingController(text: _defaultServer);
  final _accessKeyController = TextEditingController(text: _defaultAccessKey);
  final _deviceNameController = TextEditingController(text: _defaultDeviceName);
  final _newTodoController = TextEditingController();

  final TodoJournal _journal = TodoJournal();

  _PairingStep _pairingStep = _PairingStep.serverAddress;
  Uri? _baseUrl;
  String _displayHost = '';
  String _accessKey = '';
  String _userId = '';
  String _deviceName = '';

  UlsyncClient? _client;
  StreamSubscription<SyncEvent>? _liveSub;

  SessionStatus _sessionStatus = SessionStatus.connecting;
  bool _workOffline = false;
  bool _connectionLost = false;
  bool _busy = false;
  String? _formError;
  bool _showTrash = false;

  int _todoSequence = 0;

  @override
  void initState() {
    super.initState();
    // The engine cannot import Flutter. This is the one kick: process
    // woke, drop the half-open live socket and catch up.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_liveSub?.cancel());
    unawaited(_client?.close());
    _serverController.dispose();
    _accessKeyController.dispose();
    _deviceNameController.dispose();
    _newTodoController.dispose();
    super.dispose();
  }

  /// Forwards a process wake to [UlsyncClient.notifyResumed].
  ///
  /// Lock screen, app switcher, and laptop sleep freeze the isolate.
  /// Live reconnect and the 45s silence watchdog do not run until Dart
  /// timers fire again. The engine owns catch-up after that call; this
  /// widget does not call [UlsyncClient.syncOnce] here.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    final client = _client;
    if (client == null) {
      return;
    }
    unawaited(client.notifyResumed());
  }

  void _onJournalChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Maps engine events to strip text. [SessionStatus.offline] is only Work offline.
  ///
  /// [SyncConnectionLost] while mute is off is [SessionStatus.reconnecting], never
  /// the Offline copy — a killed store must not look like the cloud button.
  SessionStatus _deriveSessionStatus() {
    if (_workOffline) {
      return SessionStatus.offline;
    }
    if (_connectionLost) {
      return SessionStatus.reconnecting;
    }
    if (_sessionStatus == SessionStatus.unreachable) {
      return SessionStatus.unreachable;
    }
    if (_sessionStatus == SessionStatus.live) {
      return SessionStatus.live;
    }
    return SessionStatus.connecting;
  }

  Future<void> _continueFromServer() async {
    final text = _serverController.text.trim();
    if (text.isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      final base = Uri.parse(text);
      await pingHealth(base);
      if (!mounted) {
        return;
      }
      setState(() {
        _baseUrl = base;
        _displayHost = displayHost(base);
        _pairingStep = _PairingStep.signIn;
        _busy = false;
      });
    } on HealthCheckException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _formError = e.message;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _formError = const HealthCheckException(
          "Can't reach this server. Check the address and that the server is running.",
        ).message;
        _busy = false;
      });
    }
  }

  /// Opens sync for [_deviceName] after pairing.
  ///
  /// The device name is both the library [UlsyncClient.open] instance label
  /// and [sourceId] for this window. The library picks IndexedDB on the web
  /// and Application Support on IO; the widget never holds a path.
  Future<UlsyncClient> _createClient() async {
    final base = _baseUrl;
    if (base == null || _deviceName.isEmpty || _userId.isEmpty) {
      throw StateError('pairing context missing');
    }
    return UlsyncClient.open(
      name: _deviceName,
      baseUrl: base,
      origin: kUlsyncOrigin,
      userScope: _userId,
      sourceId: _deviceName,
      tokenProvider: () async => _accessKey,
      adapters: [
        buildTodoAdapter(journal: _journal, onChanged: _onJournalChanged),
      ],
    );
  }

  /// Replaces [UlsyncClient] so Work offline can mute the feed without
  /// dropping the local journal or the dirty queue.
  ///
  /// [UlsyncClient.live] starts a background ingest that runs until
  /// [UlsyncClient.close]. Cancelling the app's [StreamSubscription] does
  /// not stop that loop (round-1 live trap): remote trash would still land
  /// in the journal while the strip said Offline, and I5 would be untestable.
  /// The engine cannot pause the live feed in this step.
  ///
  /// Close + [UlsyncClient.open] with the **same** [name] is the mute that
  /// still allows [UlsyncClient.write] / [UlsyncClient.writeAll] (I6, I8).
  /// Caching a filesystem path would put IO details back in the widget and
  /// break the web, where [name] is an IndexedDB key. The in-memory
  /// [TodoJournal] is not cleared. [syncOnce] must **not** run on the
  /// offline instance: that would pull the remote trash we just muted.
  /// Catch-up is only [startLive], which pushes dirty first, then pulls (I5:
  /// local `done` and remote `deleted` meet after Online).
  ///
  /// If [syncOnce] fails after close, this keeps the new client **without**
  /// live so later writes do not hit `UlsyncClient is closed`.
  Future<void> _replaceClient({required bool startLive}) async {
    await _liveSub?.cancel();
    _liveSub = null;
    final previous = _client;
    _client = null;
    await previous?.close();

    final next = await _createClient();
    _client = next;
    if (!startLive) {
      return;
    }
    try {
      await next.syncOnce();
      _liveSub = next.live().listen(_onLiveEvent, onError: _onLiveError);
    } catch (_) {
      await _liveSub?.cancel();
      _liveSub = null;
      rethrow;
    }
  }

  Future<void> _signIn() async {
    final base = _baseUrl;
    if (base == null || _busy) {
      return;
    }
    final key = _accessKeyController.text.trim();
    if (key.isEmpty) {
      return;
    }
    final safeDevice = safeDeviceId(_deviceNameController.text);
    if (safeDevice == null) {
      setState(() {
        _formError =
            'Device name must use letters, digits, dot, underscore, hyphen '
            'only (no spaces or path segments).';
      });
      return;
    }

    setState(() {
      _busy = true;
      _formError = null;
    });

    UlsyncClient? client;
    try {
      final who = await fetchWhoAmI(baseUrl: base, accessKey: key);
      _accessKey = key;
      _deviceName = safeDevice;
      _userId = who.userId;
      _journal.clear();
      _todoSequence = 0;

      client = await _createClient();
      await client.syncOnce();
      _liveSub = client.live().listen(_onLiveEvent, onError: _onLiveError);
      if (!mounted) {
        await client.close();
        return;
      }
      setState(() {
        _client = client;
        _pairingStep = _PairingStep.signedIn;
        _sessionStatus = SessionStatus.connecting;
        _workOffline = false;
        _connectionLost = false;
        _showTrash = false;
        _busy = false;
      });
    } on SignInException catch (e) {
      await client?.close();
      if (!mounted) {
        return;
      }
      setState(() {
        _formError = e.message;
        _busy = false;
      });
    } catch (e) {
      await client?.close();
      if (!mounted) {
        return;
      }
      setState(() {
        _formError = '$e';
        _busy = false;
      });
    }
  }

  void _onLiveEvent(SyncEvent event) {
    if (!mounted) {
      return;
    }
    switch (event) {
      case SyncConnectionLost():
        setState(() {
          _connectionLost = true;
          if (!_workOffline) {
            _sessionStatus = SessionStatus.reconnecting;
          }
        });
      case SyncConnectionRestored():
        setState(() {
          _connectionLost = false;
          if (!_workOffline) {
            _sessionStatus = SessionStatus.live;
          }
        });
      case SyncApplied():
      case SyncCursorAdvanced():
      case SyncUnknownType():
        break;
    }
  }

  void _onLiveError(Object error) {
    if (!mounted || _workOffline) {
      return;
    }
    setState(() {
      _sessionStatus = SessionStatus.unreachable;
      _formError = '$error';
    });
  }

  Future<void> _signOut() async {
    await _liveSub?.cancel();
    _liveSub = null;
    await _client?.close();
    if (!mounted) {
      return;
    }
    setState(() {
      _client = null;
      _pairingStep = _PairingStep.serverAddress;
      _journal.clear();
      _showTrash = false;
      _workOffline = false;
      _connectionLost = false;
      _sessionStatus = SessionStatus.connecting;
      _formError = null;
    });
  }

  Future<void> _setWorkOffline(bool offline) async {
    if (_client == null || _workOffline == offline || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      if (offline) {
        await _replaceClient(startLive: false);
        if (!mounted) {
          return;
        }
        setState(() {
          _workOffline = true;
          _connectionLost = false;
        });
        return;
      }

      await _replaceClient(startLive: true);
      if (!mounted) {
        return;
      }
      setState(() {
        _workOffline = false;
        _connectionLost = false;
        _sessionStatus = SessionStatus.live;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _formError = '$e';
        if (!offline) {
          _sessionStatus = SessionStatus.unreachable;
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  String _nextTodoId() {
    _todoSequence += 1;
    final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return '$_deviceName-$micros-$_todoSequence';
  }

  /// Adds a row after local persist. Catch-up is the engine's job while live runs.
  ///
  /// [UlsyncClient.write] returns after persist and does not throw
  /// [UlsyncNetworkException]. Calling [UlsyncClient.syncOnce] here would teach
  /// authors that Milk was not saved until HTTP answered.
  Future<void> _addTodo() async {
    final client = _client;
    if (client == null || _busy) {
      return;
    }
    final title = _newTodoController.text.trim();
    if (title.isEmpty) {
      return;
    }
    final id = _nextTodoId();
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      await client.write(
        entityType: kTodoEntityType,
        id: id,
        persist: () async {
          _journal.setTitle(id, title);
          _onJournalChanged();
        },
      );
      _newTodoController.clear();
    } catch (e) {
      if (mounted) {
        setState(() {
          // Persist or closed-client failures only; write does not throw network.
          _formError = '$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  /// Toggles done after local persist; the engine drains while live runs.
  ///
  /// A store outage is [SessionStatus.reconnecting] on the strip, not a form
  /// error: the checkbox already changed in [TodoJournal].
  Future<void> _setDone(String id, bool done) async {
    final client = _client;
    if (client == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      await client.write(
        entityType: kTodoEntityType,
        id: id,
        part: kTodoPartDone,
        persist: () async {
          _journal.setDone(id, done);
          _onJournalChanged();
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _formError = '$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  /// Trash or restore after local persist; catch-up stays in the engine.
  Future<void> _setDeleted(String id, bool deleted) async {
    final client = _client;
    if (client == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      await client.write(
        entityType: kTodoEntityType,
        id: id,
        part: kTodoPartDeleted,
        persist: () async {
          _journal.setDeleted(id, deleted);
          _onJournalChanged();
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _formError = '$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  /// Sends one [writeAll] batch of trash parts for every done, visible row.
  ///
  /// A loop of [UlsyncClient.write] would let live sync POST the first rows
  /// while the rest are still dirty; the library batch API exists for this
  /// product action (round-2 I6). Catch-up after the batch is the engine's job
  /// while live runs; this widget does not run a manual push/pull round.
  Future<void> _moveDoneToTrash() async {
    final client = _client;
    if (client == null || _busy) {
      return;
    }
    final ids = _journal.doneNotTrashedIds();
    if (ids.isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      await client.writeAll([
        for (final id in ids)
          WriteOp(
            entityType: kTodoEntityType,
            id: id,
            part: kTodoPartDeleted,
            persist: () async {
              _journal.setDeleted(id, true);
              _onJournalChanged();
            },
          ),
      ]);
    } catch (e) {
      if (mounted) {
        setState(() {
          _formError = '$e';
        });
      }
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
    return switch (_pairingStep) {
      _PairingStep.serverAddress => _buildServerScreen(context),
      _PairingStep.signIn => _buildSignInScreen(context),
      _PairingStep.signedIn =>
        _showTrash ? _buildTrashScreen(context) : _buildTodoScreen(context),
    };
  }

  Widget _buildServerScreen(BuildContext context) {
    final canContinue = _serverController.text.trim().isNotEmpty && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Todos')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: ListView(
          children: [
            Text(
              'Your list stays on the server you choose.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _serverController,
              decoration: const InputDecoration(
                labelText: 'Server address',
                hintText: 'https://sync.example.com',
                helperText:
                    'Include the port when it is not 443. '
                    'Example: http://127.0.0.1:8080',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              onSubmitted: (_) {
                if (canContinue) {
                  unawaited(_continueFromServer());
                }
              },
              onChanged: (_) => setState(() {}),
            ),
            if (_formError != null) ...[
              const SizedBox(height: 16),
              Text(
                _formError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: canContinue ? _continueFromServer : null,
              child: Text(_busy ? 'Checking…' : 'Continue'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSignInScreen(BuildContext context) {
    final keyPresent = _accessKeyController.text.trim().isNotEmpty;
    final canSignIn = keyPresent && !_busy;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in'),
        leading: BackButton(
          onPressed: _busy
              ? null
              : () {
                  setState(() {
                    _pairingStep = _PairingStep.serverAddress;
                    _formError = null;
                  });
                },
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: ListView(
          children: [
            Text(
              'Signing in to $_displayHost',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _accessKeyController,
              decoration: const InputDecoration(
                labelText: 'Access key',
                helperText:
                    'Paste the key from your identity provider. '
                    'This app does not create keys.',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _deviceNameController,
              decoration: const InputDecoration(
                labelText: 'Device name',
                helperText: 'This installation. Open a second window with a different name.',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
            ),
            if (_formError != null) ...[
              const SizedBox(height: 16),
              Text(
                _formError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: canSignIn ? _signIn : null,
              child: Text(_busy ? 'Signing in…' : 'Sign in'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sessionBanner(BuildContext context) {
    final status = _deriveSessionStatus();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Semantics(
              label: status.bannerLine(host: _displayHost),
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: status.indicatorColor(scheme),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                status.bannerLine(host: _displayHost),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _signedInAppBarActions(BuildContext context) {
    return [
      IconButton(
        tooltip: 'Work offline',
        onPressed: _busy
            ? null
            : () => unawaited(_setWorkOffline(!_workOffline)),
        icon: Icon(_workOffline ? Icons.cloud_off : Icons.cloud_outlined),
      ),
      PopupMenuButton<_AccountAction>(
        onSelected: (action) {
          switch (action) {
            case _AccountAction.signOut:
              unawaited(_signOut());
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem<_AccountAction>(
            enabled: false,
            child: Text('Signed in as $_userId'),
          ),
          PopupMenuItem<_AccountAction>(
            enabled: false,
            child: Text(_displayHost),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem<_AccountAction>(
            value: _AccountAction.signOut,
            child: Text('Sign out'),
          ),
        ],
      ),
    ];
  }

  Widget _buildTodoScreen(BuildContext context) {
    final todos = _journal.activeTodos();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Todos'),
        actions: _signedInAppBarActions(context),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sessionBanner(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newTodoController,
                    decoration: const InputDecoration(
                      labelText: 'New to-do',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => unawaited(_addTodo()),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : () => unawaited(_addTodo()),
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
          if (_formError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _formError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy || _journal.doneNotTrashedIds().isEmpty
                  ? null
                  : () => unawaited(_moveDoneToTrash()),
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Move done to trash'),
            ),
          ),
          Expanded(
            child: todos.isEmpty
                ? Center(
                    child: Text(
                      'No to-dos yet',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: todos.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final todo = todos[index];
                      return _TodoRow(
                        todo: todo,
                        busy: _busy,
                        onDoneChanged: (v) => unawaited(_setDone(todo.id, v)),
                        onTrash: () => unawaited(_setDeleted(todo.id, true)),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => setState(() => _showTrash = true),
        icon: const Icon(Icons.delete_outline),
        label: Text('Trash (${_journal.trashedTodos().length})'),
      ),
    );
  }

  Widget _buildTrashScreen(BuildContext context) {
    final trashed = _journal.trashedTodos();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        leading: BackButton(
          onPressed: () => setState(() => _showTrash = false),
        ),
        actions: _signedInAppBarActions(context),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sessionBanner(context),
          Expanded(
            child: trashed.isEmpty
                ? Center(
                    child: Text(
                      'Trash is empty',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: trashed.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final todo = trashed[index];
                      return ListTile(
                        title: Text(
                          todo.title.isEmpty ? '(untitled)' : todo.title,
                          style: todo.done
                              ? const TextStyle(
                                  decoration: TextDecoration.lineThrough,
                                )
                              : null,
                        ),
                        subtitle: Text(formatTodoSubtitle(todo)),
                        trailing: TextButton(
                          onPressed: _busy
                              ? null
                              : () => unawaited(_setDeleted(todo.id, false)),
                          child: const Text('Restore'),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

enum _AccountAction { signOut }

/// One active list row with done checkbox, edited time, and trash action.
final class _TodoRow extends StatelessWidget {
  const _TodoRow({
    required this.todo,
    required this.busy,
    required this.onDoneChanged,
    required this.onTrash,
  });

  final Todo todo;
  final bool busy;
  final ValueChanged<bool> onDoneChanged;
  final VoidCallback onTrash;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Checkbox(
        value: todo.done,
        onChanged: busy ? null : (v) => onDoneChanged(v ?? false),
      ),
      title: Text(
        todo.title.isEmpty ? '(untitled)' : todo.title,
        style: todo.done
            ? TextStyle(
                decoration: TextDecoration.lineThrough,
                color: Theme.of(context).colorScheme.outline,
              )
            : null,
      ),
      subtitle: Text(formatTodoSubtitle(todo)),
      trailing: IconButton(
        tooltip: 'Trash',
        onPressed: busy ? null : onTrash,
        icon: const Icon(Icons.delete_outline),
      ),
    );
  }
}
