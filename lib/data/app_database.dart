import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Single local SQLite database. No cloud, no accounts.
class AppDatabase {
  AppDatabase._(this.db);
  final Database db;

  static const int schemaVersion = 2;

  static Future<void> _createModels(DatabaseExecutor d) => d.execute('''
    CREATE TABLE models(
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      file_name TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      sha256 TEXT NOT NULL,
      source TEXT NOT NULL,
      catalog_id TEXT,
      created_at INTEGER NOT NULL)''');

  /// [factory]/[path] are injectable so unit tests can use sqflite_common_ffi.
  static Future<AppDatabase> open({String? path, DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), 'local_ai.db');
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onCreate: (d, v) async {
          await d.execute('''
            CREATE TABLE conversations(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              title TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL)''');
          await d.execute('''
            CREATE TABLE messages(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              conversation_id INTEGER NOT NULL
                REFERENCES conversations(id) ON DELETE CASCADE,
              role TEXT NOT NULL CHECK(role IN ('user','assistant')),
              content TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'complete',
              created_at INTEGER NOT NULL)''');
          await d.execute(
              'CREATE INDEX idx_messages_conv ON messages(conversation_id, id)');
          await d.execute('''
            CREATE TABLE settings(
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL)''');
          await _createModels(d);
        },
        onUpgrade: (d, oldV, newV) async {
          if (oldV < 2) await _createModels(d);
        },
      ),
    );
    return AppDatabase._(db);
  }

  Future<void> close() => db.close();
}
