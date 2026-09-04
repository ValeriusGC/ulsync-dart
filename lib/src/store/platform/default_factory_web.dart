import 'package:sembast/sembast.dart';
import 'package:sembast_web/sembast_web.dart' as web;

/// IndexedDB-backed store used in the browser.
DatabaseFactory get defaultDatabaseFactory => web.databaseFactoryWeb;
