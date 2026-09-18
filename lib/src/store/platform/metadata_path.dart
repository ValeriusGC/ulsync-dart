/// Metadata location for the current platform, from a validated instance name.
///
/// Resolved at compile time the same way as the sembast factory: the branch
/// that is unavailable on the target is not compiled. Web never sees
/// `path_provider`. IO never sees IndexedDB. Engine tests pass `inMemory:
/// true` and do not call this resolver.
library;

export 'metadata_path_stub.dart'
    if (dart.library.io) 'metadata_path_io.dart'
    if (dart.library.js_interop) 'metadata_path_web.dart';
