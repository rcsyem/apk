import 'package:sqflite/sqflite.dart';
import 'app_database.dart';

enum ModelSource { catalog, imported }

class InstalledModel {
  const InstalledModel({
    required this.id,
    required this.name,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    required this.source,
    required this.createdAt,
    this.catalogId,
  });
  final String id;
  final String name;
  final String fileName;
  final int sizeBytes;
  final String sha256;
  final ModelSource source;
  final String? catalogId;
  final DateTime createdAt;

  factory InstalledModel.fromMap(Map<String, Object?> m) => InstalledModel(
        id: m['id'] as String,
        name: m['name'] as String,
        fileName: m['file_name'] as String,
        sizeBytes: m['size_bytes'] as int,
        sha256: m['sha256'] as String,
        source: ModelSource.values.byName(m['source'] as String),
        catalogId: m['catalog_id'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'file_name': fileName,
        'size_bytes': sizeBytes,
        'sha256': sha256,
        'source': source.name,
        'catalog_id': catalogId,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

class ModelRepository {
  ModelRepository(this._app);
  final AppDatabase _app;

  Future<List<InstalledModel>> list() async =>
      (await _app.db.query('models', orderBy: 'created_at DESC'))
          .map(InstalledModel.fromMap)
          .toList();

  Future<void> insert(InstalledModel m) => _app.db
      .insert('models', m.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> delete(String id) =>
      _app.db.delete('models', where: 'id = ?', whereArgs: [id]);
}
