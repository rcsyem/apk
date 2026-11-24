import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import '../data/model_repository.dart';
import '../native/native_info.dart';
import 'file_hash.dart';
import 'gguf_info.dart';

class ImportException implements Exception {
  ImportException(this.messageAr);
  final String messageAr;
  @override
  String toString() => 'ImportException($messageAr)';
}

/// Imports a user-picked GGUF into app-private storage. Local only; nothing is uploaded.
class ModelImporter {
  ModelImporter({
    required this.modelsDir,
    required this.nativeInfo,
    required this.repo,
    this.storageMarginBytes = 64 * 1024 * 1024,
  });
  final Directory modelsDir;
  final NativeInfo nativeInfo;
  final ModelRepository repo;
  final int storageMarginBytes;

  /// [moveSource]: the picker hands us a temporary copy; try a rename first so a
  /// multi-hundred-MB file is not duplicated.
  Future<InstalledModel> importFile(String sourcePath, {bool moveSource = false}) async {
    final src = File(sourcePath);
    if (!await src.exists()) throw ImportException('الملف المحدد غير موجود.');
    final size = await src.length();

    final GgufInfo info;
    try {
      info = await Isolate.run(() => GgufInfo.readSync(sourcePath));
    } on FormatException {
      throw ImportException('الملف ليس بصيغة GGUF صالحة أو أنه تالف.');
    }
    // Preliminary chat-template check (metadata only; nothing is loaded and nothing is copied yet).
    // A model without a usable template would import fine and then fail at the first message.
    final tpl = info.chatTemplateVerdict;
    if (!tpl.usable) throw ImportException(tpl.messageAr);

    await modelsDir.create(recursive: true);
    final free = await nativeInfo.freeStorageBytes(modelsDir.path);
    if (!moveSource && free != null && free < size + storageMarginBytes) {
      throw ImportException('مساحة التخزين غير كافية لاستيراد هذا الملف.');
    }

    final id = 'imp-${DateTime.now().microsecondsSinceEpoch}';
    final fileName = '$id.gguf';
    final tmp = File(p.join(modelsDir.path, '$fileName.tmp'));
    final dst = File(p.join(modelsDir.path, fileName));
    try {
      var moved = false;
      if (moveSource) {
        try {
          await src.rename(tmp.path);
          moved = true;
        } on FileSystemException {
          moved = false; // different volume: fall back to copy
        }
      }
      if (!moved) {
        await src.copy(tmp.path);
        if (moveSource) {
          try {
            await src.delete();
          } catch (_) {}
        }
      }
      final digest = await sha256OfFile(tmp);
      await tmp.rename(dst.path);
      final model = InstalledModel(
        id: id,
        name: p.basenameWithoutExtension(sourcePath),
        fileName: fileName,
        sizeBytes: size,
        sha256: digest,
        source: ModelSource.imported,
        createdAt: DateTime.now(),
      );
      await repo.insert(model);
      return model;
    } on FileSystemException {
      await _cleanup(tmp, dst);
      throw ImportException('تعذّر نسخ الملف (قد تكون المساحة غير كافية).');
    } catch (_) {
      await _cleanup(tmp, dst);
      rethrow;
    }
  }

  Future<void> _cleanup(File tmp, File dst) async {
    for (final f in [tmp, dst]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}
