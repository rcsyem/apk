import 'dart:async';
import 'dart:io';
import 'package:local_ai_assistant/application/app_settings.dart';
import 'package:local_ai_assistant/application/chat_controller.dart';
import 'package:local_ai_assistant/data/app_database.dart';
import 'package:local_ai_assistant/data/chat_repository.dart';
import 'package:local_ai_assistant/data/model_repository.dart';
import 'package:local_ai_assistant/engine/inference_engine.dart';
import 'package:local_ai_assistant/models/model_manager.dart';
import 'package:local_ai_assistant/native/native_info.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'gguf_builder.dart';

extension SnapshotX on MemorySnapshot {
  MemorySnapshot lowAvailable(int avail) => MemorySnapshot(
      totalBytes: totalBytes, availableBytes: avail, thresholdBytes: thresholdBytes, lowMemory: lowMemory);
}

class FakeNative implements NativeInfo {
  MemorySnapshot snapshot = const MemorySnapshot(
      totalBytes: 8 << 30, availableBytes: 4 << 30, thresholdBytes: 0, lowMemory: false);
  int? freeBytes = 100 << 30;
  final StreamController<int> trim = StreamController<int>.broadcast();
  @override
  Future<MemorySnapshot> memorySnapshot() async => snapshot;
  @override
  Future<int?> freeStorageBytes(String path) async => freeBytes;
  @override
  Future<int?> processRssBytes() async => null;
  @override
  Stream<int> get trimMemoryLevels => trim.stream;
}

/// Scripted engine double (NOT llama): used only to test application logic.
class FakeEngine implements InferenceEngine {
  final List<String> log = [];
  List<String> script = ['مرحبا', ' بك'];
  Duration pieceDelay = Duration.zero;
  Duration loadDelay = Duration.zero;
  Object? failLoadWith;
  bool throwAfterFirstPiece = false;
  List<ChatTurn> lastTurns = const [];
  bool _stopFlag = false;
  EngineState _state = EngineState.idle;
  final _ctl = StreamController<EngineState>.broadcast();
  int _ctx = 0;

  void _set(EngineState s) {
    _state = s;
    _ctl.add(s);
  }

  @override
  EngineState get state => _state;
  @override
  Stream<EngineState> get stateChanges => _ctl.stream;
  @override
  int get contextLength => _ctx;
  @override
  GenerationStats? get lastStats => null;

  @override
  Future<void> loadModel(ModelLoadRequest r) async {
    log.add('load:${r.path.split('/').last}');
    if (_state != EngineState.idle) throw EngineException(EngineErrorCode.busy);
    _set(EngineState.loading);
    if (loadDelay > Duration.zero) await Future<void>.delayed(loadDelay);
    if (failLoadWith != null) {
      _set(EngineState.idle);
      throw failLoadWith!;
    }
    _ctx = r.contextLength;
    _set(EngineState.ready);
  }

  @override
  Future<int> countPromptTokens(List<ChatTurn> turns) async =>
      turns.fold<int>(0, (a, t) => a + t.content.length ~/ 4 + 4);

  @override
  Stream<String> generate(List<ChatTurn> turns, GenerationParams params) async* {
    log.add('generate:${turns.length}');
    lastTurns = turns;
    _stopFlag = false;
    _set(EngineState.generating);
    try {
      for (var i = 0; i < script.length; i++) {
        if (_stopFlag) break;
        if (pieceDelay > Duration.zero) await Future<void>.delayed(pieceDelay);
        if (_stopFlag) break;
        yield script[i];
        if (throwAfterFirstPiece && i == 0) throw EngineException(EngineErrorCode.generationFailed);
      }
    } finally {
      _set(EngineState.ready);
    }
  }

  @override
  Future<void> stop() async {
    log.add('stop');
    _stopFlag = true;
  }

  @override
  Future<void> unload() async {
    log.add('unload');
    _set(EngineState.unloading);
    _set(EngineState.idle);
  }
}

class TestEnv {
  late Directory dir;
  late AppDatabase db;
  late ChatRepository chatRepo;
  late ModelRepository modelRepo;
  late AppSettings settings;
  final native = FakeNative();
  final engine = FakeEngine();
  late ModelManager models;
  late ChatController chat;

  static Future<TestEnv> create({int models = 1}) async {
    sqfliteFfiInit();
    final e = TestEnv();
    e.dir = await Directory.systemTemp.createTemp('lai_test');
    e.db = await AppDatabase.open(path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    e.chatRepo = ChatRepository(e.db);
    e.modelRepo = ModelRepository(e.db);
    e.settings = AppSettings(e.chatRepo);
    await e.settings.load();
    e.models = ModelManager(
      engine: e.engine,
      repo: e.modelRepo,
      settings: e.settings,
      modelsDir: e.dir,
      native: e.native,
      threads: 1,
    );
    for (var i = 1; i <= models; i++) {
      final f = File('${e.dir.path}/m$i.gguf');
      await f.writeAsBytes(buildGguf());
      await e.modelRepo.insert(InstalledModel(
        id: 'm$i',
        name: 'Model $i',
        fileName: 'm$i.gguf',
        sizeBytes: await f.length(),
        sha256: 'x',
        source: ModelSource.imported,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000 + i),
      ));
    }
    await e.models.init();
    if (models > 0) await e.settings.setActiveModelId('m1');
    e.chat = ChatController(e.chatRepo, e.engine, e.models, e.settings);
    await e.chat.init();
    return e;
  }

  Future<void> dispose() async {
    chat.dispose();
    models.dispose();
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
