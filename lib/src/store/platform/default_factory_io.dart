import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart' as io;

/// File-backed store used on mobile and desktop.
DatabaseFactory get defaultDatabaseFactory => io.databaseFactoryIo;
