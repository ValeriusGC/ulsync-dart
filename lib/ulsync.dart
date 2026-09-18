/// Entity-level last-write-wins synchronization for Flutter applications.
///
/// A record kit is every envelope of one `(entityType, id)`: `full` plus
/// every named part. That kit is **indivisible** and must be **complete** —
/// no cell is optional, and no SPEC batch of 500 may cut it in half.
/// See the README and the `protocol/` submodule for setup and the wire
/// format.
///
/// Applications talk to [UlsyncClient.open], [EntityAdapter], [WriteOp],
/// [SyncReport], and [SyncEvent]. Related edits use [UlsyncClient.writeAll].
/// The metadata engine, filesystem path, and `path_provider` stay inside
/// `lib/src/`. Wire envelopes are not part of the sync event stream.
/// Live-feed line parsing stays internal.
library;

export 'src/engine/entity_adapter.dart' show EntityAdapter;
export 'src/engine/incoming_envelope_meta.dart' show IncomingEnvelopeMeta;
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
