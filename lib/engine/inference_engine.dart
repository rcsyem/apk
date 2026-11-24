/// Engine-agnostic contract. UI and application layers depend ONLY on this.
/// FFI today; JNI or a GPU backend later, without touching callers.
enum EngineState { idle, loading, ready, generating, unloading, error }

enum EngineErrorCode {
  modelNotFound,
  modelCorrupt,
  modelIncompatible,
  outOfMemory,
  generationFailed,
  contextExceeded,
  busy,
  notReady,
  unknown,
}

class EngineException implements Exception {
  EngineException(this.code, [this.detail]);
  final EngineErrorCode code;
  final String? detail;
  @override
  String toString() => 'EngineException($code${detail == null ? '' : ': $detail'})';
}

enum ChatRole { system, user, assistant }

class ChatTurn {
  const ChatTurn(this.role, this.content);
  final ChatRole role;
  final String content;
}

class ModelLoadRequest {
  const ModelLoadRequest({
    required this.path,
    this.contextLength = 2048,
    this.threads = 4,
  });
  final String path;
  final int contextLength;
  final int threads;
}

class GenerationParams {
  const GenerationParams({this.temperature = 0.7, this.maxNewTokens = 512});
  final double temperature;
  final int maxNewTokens;
}

/// Real engine counters for one generation (not piece counts).
class GenerationStats {
  const GenerationStats({
    required this.promptTokens,
    required this.generatedTokens,
    required this.firstTokenMs,
    required this.totalMs,
  });
  final int promptTokens;
  final int generatedTokens;
  final int firstTokenMs; // -1 if nothing was produced
  final int totalMs;
  double get tokensPerSecond => totalMs > 0 ? generatedTokens * 1000 / totalMs : 0;
}

abstract interface class InferenceEngine {
  EngineState get state;
  int get contextLength;
  GenerationStats? get lastStats;
  Stream<EngineState> get stateChanges;

  /// Loads exactly one model. Implementations MUST serialize load/unload and
  /// reject concurrent calls with [EngineErrorCode.busy].
  Future<void> loadModel(ModelLoadRequest request);

  /// Streams decoded text pieces; completes on EOG, token limit, or stop.
  Stream<String> generate(List<ChatTurn> turns, GenerationParams params);

  /// Prompt size in tokens after applying the model's chat template.
  Future<int> countPromptTokens(List<ChatTurn> turns);

  /// Cooperative stop; the generate stream completes shortly after.
  Future<void> stop();

  /// Stops generation, frees model+context; completes only once released.
  Future<void> unload();
}
