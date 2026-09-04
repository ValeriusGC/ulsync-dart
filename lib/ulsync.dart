/// Entity-level last-write-wins synchronization for Flutter applications.
///
/// See the README for setup and the `protocol/` submodule for the wire format.
///
/// Applications talk to [UlsyncClient], [EntityAdapter], [SyncReport], and
/// [SyncEvent]. Wire envelopes are not part of the sync event stream.
/// Live-feed line parsing stays internal.
library;

export 'src/engine/entity_adapter.dart' show EntityAdapter;
export 'src/engine/sync_engine.dart' show UlsyncClient;
export 'src/engine/sync_event.dart'
    show
        SyncEvent,
        SyncApplied,
        SyncedEntity,
        SyncCursorAdvanced,
        SyncConnectionLost,
        SyncConnectionRestored,
        SyncUnknownType;
export 'src/engine/sync_report.dart' show SyncReport;
export 'src/protocol/envelope.dart' show Envelope;
export 'src/protocol/errors.dart' show UlsyncProtocolException;
export 'src/store/entity_state.dart' show EntityState;
export 'src/store/sembast_metadata_store.dart' show SembastMetadataStore;
export 'src/transport/sync_transport.dart'
    show
        SyncTransport,
        PushResult,
        PullPage,
        LiveMessage,
        LiveEnvelope,
        LiveCursor,
        LiveHeartbeat,
        LiveConnectionState;
export 'src/transport/http_sync_transport.dart' show HttpSyncTransport;
export 'src/transport/exceptions.dart'
    show
        UlsyncTransportException,
        UlsyncNetworkException,
        UlsyncServerException,
        UlsyncUnauthorized,
        UlsyncRequestRejected;
