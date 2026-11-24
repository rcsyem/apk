import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../application/app_settings.dart';
import '../application/async_lock.dart';
import '../application/error_messages.dart';
import '../data/model_repository.dart';
import '../engine/inference_engine.dart';
import '../memory/memory_estimator.dart';
import '../native/native_info.dart';
import 'gguf_info.dart';

/// Owns the single-model policy: at most one model loaded, loads/unloads are
/// serialized, and switching always stops -> unloads (awaited) -> loads.
class ModelManager extends ChangeNotifier {
  ModelManager({
    required this.engine,
    required this.repo,
    required this.settings,
    required this.modelsDir,
    required this.native,
    this.estimator = const MemoryEstimator(),
    this.policy = const MemoryPolicy(),
    this.threads,
  });

  final InferenceEngine engine;
  final ModelRepository repo;
  final AppSettings settings;
  final Directory modelsDir;
  final NativeInfo native;
  final MemoryEstimator estimator;
  final MemoryPolicy policy;
  final int? threads;

  final AsyncLock _lock = AsyncLock();
  final Map<String, GgufInfo> _ggufCache = {};

  List<InstalledModel> installed = [];
  String? loadedId;
  int? loadedContext;
  bool loading = false;
  int? lastLoadMs;
  int? lastLoadRssDeltaBytes;

  InstalledModel? get active {
    final id = settings.activeModelId;
    for (final m in installed) {
      if (m.id == id) return m;
    }
    return null;
  }

  File fileOf(InstalledModel m) => File(p.join(modelsDir.path, m.fileName));

  /// Starting default (to be tuned by measurement): up to 4 threads.
  int get _threads => threads ?? (Platform.numberOfProcessors.clamp(1, 4) as int);

  Future<void> init() async {
    await refresh();
    if (settings.activeModelId != null && active == null) {
      await settings.setActiveModelId(null);
    }
  }

  Future<void> refresh() async {
    installed = await repo.list();
    notifyListeners();
  }

  Future<void> register(InstalledModel m) async {
    await refresh();
    if (settings.activeModelId == null) await select(m.id);
  }

  Future<void> select(String id) => _lock.run(() async {
        if (loadedId != null && loadedId != id) await _unloadLocked();
        await settings.setActiveModelId(id);
        notifyListeners();
      });

  /// Contexts the memory policy accepts for the active model right now.
  Future<List<int>> allowedContexts() async {
    final m = active;
    if (m == null) return const [];
    final info = await _gguf(m);
    return policy.allowedContexts(estimator, info, await native.memorySnapshot());
  }

  Future<void> ensureLoaded() => _lock.run(_ensureLoadedLocked);

  Future<void> unload() => _lock.run(_unloadLocked);

  Future<void> delete(String id) => _lock.run(() async {
        if (loadedId == id) await _unloadLocked();
        final m = installed.where((x) => x.id == id).toList();
        if (settings.activeModelId == id) await settings.setActiveModelId(null);
        await repo.delete(id);
        if (m.isNotEmpty) {
          final f = fileOf(m.first);
          if (await f.exists()) await f.delete();
        }
        _ggufCache.remove(id);
        await refresh();
      });

  Future<GgufInfo> _gguf(InstalledModel m) async {
    final cached = _ggufCache[m.id];
    if (cached != null) return cached;
    final path = fileOf(m).path;
    try {
      final info = await Isolate.run(() => GgufInfo.readSync(path));
      _ggufCache[m.id] = info;
      return info;
    } on FormatException {
      throw ModelLoadException('ملف النموذج تالف أو ليس بصيغة GGUF صالحة.');
    } on FileSystemException {
      throw ModelLoadException('ملف النموذج غير موجود.');
    }
  }

  Future<void> _ensureLoadedLocked() async {
    final m = active;
    if (m == null) {
      throw ModelLoadException('لم يتم اختيار نموذج. اختر نموذجاً أو نزّله من الإعدادات.');
    }
    final ctx = settings.contextLength;
    if (loadedId == m.id && loadedContext == ctx && engine.state == EngineState.ready) return;
    if (loadedId != null || engine.state != EngineState.idle) await _unloadLocked();

    final file = fileOf(m);
    if (!await file.exists()) {
      throw ModelLoadException('ملف النموذج غير موجود. أعد تنزيله أو استيراده.');
    }
    final info = await _gguf(m);
    // Preliminary chat-template check BEFORE anything is loaded into memory. (The engine remains the
    // final authority: an unrecognised template still surfaces as EngineErrorCode.modelIncompatible.)
    final tpl = info.chatTemplateVerdict;
    if (!tpl.usable) throw ModelLoadException(tpl.messageAr);
    final decision = policy.evaluate(estimator.estimate(info, ctx), await native.memorySnapshot());
    if (decision.verdict == MemoryVerdict.deny) throw ModelLoadException(decision.messageAr);

    loading = true;
    notifyListeners();
    final sw = Stopwatch()..start();
    final before = await native.processRssBytes();
    try {
      await engine.loadModel(ModelLoadRequest(path: file.path, contextLength: ctx, threads: _threads));
    } finally {
      loading = false;
      notifyListeners();
    }
    sw.stop();
    lastLoadMs = sw.elapsedMilliseconds;
    final after = await native.processRssBytes();
    if (before != null && after != null) lastLoadRssDeltaBytes = after - before;
    loadedId = m.id;
    loadedContext = ctx;
    // Local measurement log for later calibration (never leaves the device).
    await settings.recordMeasurement(
        'last_load', 'model=${m.id} ctx=$ctx ms=$lastLoadMs rssDelta=${lastLoadRssDeltaBytes ?? "n/a"}');
    notifyListeners();
  }

  Future<void> _unloadLocked() async {
    await engine.stop();
    await engine.unload(); // completes only after native memory is released
    loadedId = null;
    loadedContext = null;
    notifyListeners();
  }
}
