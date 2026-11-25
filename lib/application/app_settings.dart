import 'package:flutter/foundation.dart';
import '../data/chat_repository.dart';

/// Only the settings the spec allows: model choice, context length, temperature.
class AppSettings extends ChangeNotifier {
  AppSettings(this._repo);
  final ChatRepository _repo;

  static const int defaultContext = 2048;
  static const int minContext = 512;
  static const int maxContext = 131072;
  static const double defaultTemperature = 0.7;
  static const double minTemperature = 0.0;
  static const double maxTemperature = 1.5;

  String? activeModelId;
  int contextLength = defaultContext;
  double temperature = defaultTemperature;

  Future<void> load() async {
    final id = await _repo.getSetting('active_model_id');
    activeModelId = (id == null || id.isEmpty) ? null : id;
    final parsedCtx = int.tryParse(await _repo.getSetting('context_length') ?? '') ?? defaultContext;
    contextLength = parsedCtx.clamp(minContext, maxContext);
    final t = double.tryParse(await _repo.getSetting('temperature') ?? '');
    temperature = (t == null || !t.isFinite) ? defaultTemperature : t.clamp(minTemperature, maxTemperature).toDouble();
    notifyListeners();
  }

  Future<void> setActiveModelId(String? id) async {
    activeModelId = id;
    await _repo.setSetting('active_model_id', id ?? '');
    notifyListeners();
  }

  Future<void> setContextLength(int v) async {
    final clamped = v.clamp(minContext, maxContext);
    contextLength = clamped;
    await _repo.setSetting('context_length', '$clamped');
    notifyListeners();
  }

  Future<void> setTemperature(double v) async {
    temperature = v.clamp(minTemperature, maxTemperature).toDouble();
    await _repo.setSetting('temperature', '$temperature');
    notifyListeners();
  }

  /// Free-form measurement log (RSS deltas etc.) for later calibration. Local only.
  Future<void> recordMeasurement(String key, String value) =>
      _repo.setSetting('measure.$key', value);
}
