import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/data/app_database.dart';
import 'package:local_ai_assistant/data/model_repository.dart';
import 'package:local_ai_assistant/models/model_importer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../helpers/fakes.dart';
import '../helpers/gguf_builder.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late Directory modelsDir;
  late AppDatabase db;
  late ModelRepository repo;
  late FakeNative native;
  late ModelImporter importer;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('importer_test');
    modelsDir = Directory('${tempDir.path}/models');
    db = await AppDatabase.open(path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    repo = ModelRepository(db);
    native = FakeNative();
    importer = ModelImporter(modelsDir: modelsDir, nativeInfo: native, repo: repo);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('imports a structurally valid GGUF file and computes SHA-256', () async {
    final src = File('${tempDir.path}/valid.gguf');
    await src.writeAsBytes(buildGguf());

    final model = await importer.importFile(src.path);
    expect(model.id, startsWith('imp-'));
    expect(model.fileName, endsWith('.gguf'));
    expect(model.sha256.length, 64);
    expect(model.source, ModelSource.imported);

    final dst = File('${modelsDir.path}/${model.fileName}');
    expect(await dst.exists(), isTrue);

    final list = await repo.list();
    expect(list.length, 1);
    expect(list.first.id, model.id);
  });

  test('rejects a non-GGUF file with clear Arabic error message', () async {
    final src = File('${tempDir.path}/random.bin');
    await src.writeAsString('THIS IS NOT A GGUF FILE AT ALL');

    expect(
      () => importer.importFile(src.path),
      throwsA(isA<ImportException>().having((e) => e.messageAr, 'messageAr', contains('صيغة GGUF صالحة'))),
    );
  });

  test('rejects a truncated / corrupted GGUF file', () async {
    final src = File('${tempDir.path}/corrupt.gguf');
    await src.writeAsBytes(buildGguf(truncate: true));

    expect(
      () => importer.importFile(src.path),
      throwsA(isA<ImportException>().having((e) => e.messageAr, 'messageAr', contains('تالف'))),
    );
  });

  test('rejects an incompatible model with missing chat template', () async {
    final src = File('${tempDir.path}/notemplate.gguf');
    // chatTemplate = null simulates a raw base model without instruct template
    await src.writeAsBytes(buildGguf(chatTemplate: null));

    expect(
      () => importer.importFile(src.path),
      throwsA(isA<ImportException>().having((e) => e.messageAr, 'messageAr', contains('قالب محادثة'))),
    );
  });

  test('rejects import if free storage space is insufficient', () async {
    final src = File('${tempDir.path}/huge.gguf');
    await src.writeAsBytes(buildGguf());

    // Native reports very low free disk space (less than size + margin)
    native.freeBytes = 1024; // 1KB free

    expect(
      () => importer.importFile(src.path),
      throwsA(isA<ImportException>().having((e) => e.messageAr, 'messageAr', contains('مساحة التخزين غير كافية'))),
    );
  });
}
