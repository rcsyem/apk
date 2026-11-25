import 'dart:async';
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

/// The 12 canonical model lifecycle states specified for v0.4.8.
enum ModelLifecycleState {
  noModel,
  downloading,
  downloadPaused,
  downloaded,
  verifying,
  verified,
  loading,
  ready,
  generating,
  unloading,
  error,
  incompatible,
}

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
  }) {
    _engineSub = engine.stateChanges.listen(_onEngineStateChanged);
    settings.addListener(_onSettingsChanged);
  }

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
  StreamSubscription<EngineState>? _engineSub;
  bool _disposed = false;

  List<InstalledModel> installed = [];
  String? loadedId;
  int? loadedContext;
  bool loading = false;
  int? lastLoadMs;
  int? lastLoadRssDeltaBytes;
  ModelLifecycleState _state = ModelLifecycleState.noModel;
  String? lastErrorMessage;

  ModelLifecycleState get state => _state;

  InstalledModel? get active {
    final id = settings.activeModelId;
    if (id == null) return null;
    for (final m in installed) {
      if (m.id == id) return m;
    }
    return null;
  }

  File fileOf(InstalledModel m) => File(p.join(modelsDir.path, m.fileName));

  /// Starting default: up to 4 threads.
  int get _threads => threads ?? (Platform.numberOfProcessors.clamp(1, 4) as int);

  void _onEngineStateChanged(EngineState s) {
    if (_disposed) return;
    if (s == EngineState.generating) {
      _state = ModelLifecycleState.generating;
      notifyListeners();
    } else if (s == EngineState.ready && loadedId != null) {
      _state = ModelLifecycleState.ready;
      notifyListeners();
    } else if (s == EngineState.unloading) {
      _state = ModelLifecycleState.unloading;
      notifyListeners();
    } else if (s == EngineState.idle && loadedId == null) {
      if (_state != ModelLifecycleState.error && _state != ModelLifecycleState.incompatible) {
        _state = active == null ? ModelLifecycleState.noModel : ModelLifecycleState.downloaded;
        notifyListeners();
      }
    }
  }

  void _onSettingsChanged() {
    if (_disposed) return;
    _syncState();
    notifyListeners();
  }

  Future<void> init() async {
    await refresh();
    if (settings.activeModelId != null && active == null) {
      await settings.setActiveModelId(null);
    }
    _syncState();
  }

  Future<void> refresh() async {
    installed = await repo.list();
    _syncState();
    notifyListeners();
  }

  void _syncState() {
    if (active == null) {
      _state = ModelLifecycleState.noModel;
    } else if (loadedId == active!.id && engine.state == EngineState.ready) {
      _state = ModelLifecycleState.ready;
    } else if (loading) {
      _state = ModelLifecycleState.loading;
    } else if (_state != ModelLifecycleState.error && _state != ModelLifecycleState.incompatible) {
      _state = ModelLifecycleState.downloaded;
    }
  }

  Future<void> register(InstalledModel m) async {
    await refresh();
    if (settings.activeModelId == null) {
      await select(m.id);
    }
  }

  /// Selects and switches active model safely, stopping any generation and unloading first.
  Future<void> select(String id) => switchModel(id);

  /// Safe sequential model switching adhering to single-model memory policy:
  /// 1. Block concurrent calls via lock.
  /// 2. Stop ongoing generation safely.
  /// 3. Unload previous model & ensure native memory is freed.
  /// 4. Set new active model in settings.
  /// 5. Verify and load new model if requested.
  Future<void> switchModel(String id, {bool loadImmediately = false}) =>
      _lock.run(() async {
        if (loadedId == id && engine.state == EngineState.ready) {
          await settings.setActiveModelId(id);
          _state = ModelLifecycleState.ready;
          notifyListeners();
          return;
        }

        // 1 & 2 & 3: Stop generation and unload previous model
        if (loadedId != null || engine.state != EngineState.idle) {
          _state = ModelLifecycleState.unloading;
          notifyListeners();
          await _unloadLocked();
        }

        // 4: Set new active model
        await settings.setActiveModelId(id);
        _state = ModelLifecycleState.downloaded;
        notifyListeners();

        // 5: Load if requested
        if (loadImmediately) {
          await _ensureLoadedLocked();
        }
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
        if (loadedId == id) {
          _state = ModelLifecycleState.unloading;
          notifyListeners();
          await _unloadLocked();
        }
        final m = installed.where((x) => x.id == id).toList();
        if (settings.activeModelId == id) {
          await settings.setActiveModelId(null);
        }
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
      _state = ModelLifecycleState.incompatible;
      notifyListeners();
      throw ModelLoadException('ملف النموذج تالف أو ليس بصيغة GGUF صالحة.');
    } on FileSystemException {
      _state = ModelLifecycleState.error;
      notifyListeners();
      throw ModelLoadException('ملف النموذج غير موجود.');
    }
  }

  Future<void> _ensureLoadedLocked() async {
    final m = active;
    if (m == null) {
      _state = ModelLifecycleState.noModel;
      notifyListeners();
      throw ModelLoadException('لم يتم اختيار نموذج. اختر نموذجاً أو نزّله من الإعدادات.');
    }
    final ctx = settings.contextLength;
    if (loadedId == m.id && loadedContext == ctx && engine.state == EngineState.ready) {
      _state = ModelLifecycleState.ready;
      return;
    }
    if (loadedId != null || engine.state != EngineState.idle) {
      await _unloadLocked();
    }

    final file = fileOf(m);
    if (!await file.exists()) {
      _state = ModelLifecycleState.error;
      notifyListeners();
      throw ModelLoadException('ملف النموذج غير موجود. أعد تنزيله أو استيراده.');
    }

    final info = await _gguf(m);
    final tpl = info.chatTemplateVerdict;
    if (!tpl.usable) {
      _state = ModelLifecycleState.incompatible;
      lastErrorMessage = tpl.messageAr;
      notifyListeners();
      throw ModelLoadException(tpl.messageAr);
    }

    final decision = policy.evaluate(estimator.estimate(info, ctx), await native.memorySnapshot());
    if (decision.verdict == MemoryVerdict.deny) {
      _state = ModelLifecycleState.error;
      lastErrorMessage = decision.messageAr;
      notifyListeners();
      throw ModelLoadException(decision.messageAr);
    }

    loading = true;
    _state = ModelLifecycleState.loading;
    notifyListeners();

    final sw = Stopwatch()..start();
    final before = await native.processRssBytes();
    try {
      await engine.loadModel(ModelLoadRequest(path: file.path, contextLength: ctx, threads: _threads));
      _state = ModelLifecycleState.ready;
    } catch (e) {
      lastErrorMessage = e.toString();
      await _unloadLocked(preserveState: true);
      _state = ModelLifecycleState.error;
      notifyListeners();
      rethrow;
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

    await settings.recordMeasurement(
        'last_load', 'model=${m.id} ctx=$ctx ms=$lastLoadMs rssDelta=${lastLoadRssDeltaBytes ?? "n/a"}');
    notifyListeners();
  }

  Future<void> _unloadLocked({bool preserveState = false}) async {
    await engine.stop();
    await engine.unload(); // completes only after native memory is released
    loadedId = null;
    loadedContext = null;
    if (!preserveState) {
      _state = active == null ? ModelLifecycleState.noModel : ModelLifecycleState.downloaded;
    }
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _engineSub?.cancel();
    settings.removeListener(_onSettingsChanged);
    super.dispose();
  }
}
