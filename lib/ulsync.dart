/// Entity-level last-write-wins synchronization for Flutter applications.
///
/// See the README for setup and the `protocol/` submodule for the wire format.
///
/// Public API: [Envelope], [UlsyncProtocolException], [EntityState],
/// [SembastMetadataStore], [SyncTransport], [HttpSyncTransport],
/// [PushResult], [PullPage], [LiveMessage], [LiveEnvelope], [LiveCursor],
/// [LiveHeartbeat], and the transport failure types. Live-feed line
/// parsing stays internal.
library;

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
        LiveHeartbeat;
export 'src/transport/http_sync_transport.dart' show HttpSyncTransport;
export 'src/transport/exceptions.dart'
    show
        UlsyncTransportException,
        UlsyncNetworkException,
        UlsyncServerException,
        UlsyncUnauthorized,
        UlsyncRequestRejected;
