/// Storage implementation for the current platform.
///
/// Resolved at compile time: the branch that is unavailable on the target is
/// not compiled at all, so an application building for the web never sees
/// `dart:io` through us, and a mobile application never sees browser interop.
library;

export 'default_factory_stub.dart'
    if (dart.library.io) 'default_factory_io.dart'
    if (dart.library.js_interop) 'default_factory_web.dart';
