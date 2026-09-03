/// Entity-level last-write-wins synchronization for Flutter applications.
///
/// See the README for setup and the `protocol/` submodule for the wire format.
///
/// Public API: [Envelope] and [UlsyncProtocolException]. Live-feed parsing
/// stays internal until transport (step 13) needs it.
library;

export 'src/protocol/envelope.dart' show Envelope;
export 'src/protocol/errors.dart' show UlsyncProtocolException;
export 'src/store/entity_state.dart' show EntityState;
export 'src/store/sembast_metadata_store.dart' show SembastMetadataStore;
