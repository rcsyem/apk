import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'application/app_settings.dart';
import 'application/chat_controller.dart';
import 'data/app_database.dart';
import 'data/chat_repository.dart';
import 'data/model_repository.dart';
import 'engine/ffi_inference_engine.dart';
import 'engine/inference_engine.dart';
import 'models/download_manager.dart';
import 'models/model_importer.dart';
import 'models/model_manager.dart';
import 'native/native_info.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await AppDatabase.open();
  final chatRepo = ChatRepository(db);
  final modelRepo = ModelRepository(db);
  final native = AndroidNativeInfo();
  final support = await getApplicationSupportDirectory(); // app-private, not backed up
  final modelsDir = Directory(p.join(support.path, 'models'));
  await modelsDir.create(recursive: true);

  final settings = AppSettings(chatRepo);
  await settings.load();
  final InferenceEngine engine = FfiInferenceEngine();
  final models = ModelManager(
    engine: engine,
    repo: modelRepo,
    settings: settings,
    modelsDir: modelsDir,
    native: native,
  );
  await models.init();
  final chat = ChatController(chatRepo, engine, models, settings);
  await chat.init();

  runApp(MultiProvider(
    providers: [
      Provider<NativeInfo>.value(value: native),
      Provider<ModelRepository>.value(value: modelRepo),
      ChangeNotifierProvider<AppSettings>.value(value: settings),
      ChangeNotifierProvider<ModelManager>.value(value: models),
      ChangeNotifierProvider<ChatController>.value(value: chat),
      ChangeNotifierProvider<DownloadManager>(
          create: (_) => DownloadManager(modelsDir: modelsDir, nativeInfo: native)),
      Provider<ModelImporter>.value(
          value: ModelImporter(modelsDir: modelsDir, nativeInfo: native, repo: modelRepo)),
    ],
    child: const LocalAiApp(),
  ));
}
