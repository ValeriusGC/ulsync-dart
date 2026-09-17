/// Entity-level last-write-wins synchronization for Flutter applications.
///
/// See the README for setup and the `protocol/` submodule for the wire format.
///
/// Applications talk to [UlsyncClient], [EntityAdapter], [WriteOp],
/// [SyncReport], and [SyncEvent]. Related edits use [UlsyncClient.writeAll].
/// Wire envelopes are not part of the sync event stream.
/// Live-feed line parsing stays internal.
library;

export 'src/engine/entity_adapter.dart' show EntityAdapter;
export 'src/engine/sync_engine.dart' show UlsyncClient, WriteOp;
export 'src/engine/self_check_report.dart' show SelfCheckReport;
export 'src/protocol/origin.dart' show OriginMismatchException;
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
        SyncDiffTransport,
        SyncHelloTransport,
        HelloResult,
        DiffProbe,
        DiffGap,
        DiffVerdict,
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
