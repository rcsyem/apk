import '../engine/inference_engine.dart';

typedef TokenCounter = Future<int> Function(List<ChatTurn> turns);

class ContextTooSmallException implements Exception {
  @override
  String toString() => 'ContextTooSmallException';
}

/// Chooses which part of the history goes to the model. The full history always
/// stays in SQLite; this only decides what fits the model context.
class ContextBuilder {
  /// Returns the longest suffix of [turns] whose templated size is <= [budgetTokens].
  /// Always keeps whole messages and always includes the newest one.
  static Future<List<ChatTurn>> fit(
    List<ChatTurn> turns, {
    required int budgetTokens,
    required TokenCounter count,
  }) async {
    if (turns.isEmpty) return turns;
    final n = turns.length;
    Future<bool> fits(int start) async => (await count(turns.sublist(start))) <= budgetTokens;

    if (!await fits(n - 1)) throw ContextTooSmallException();
    var lo = 0, hi = n - 1; // token count is monotonic in the suffix length
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (await fits(mid)) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    var start = lo;
    // Do not begin with a dangling assistant reply: keep proper turn boundaries.
    if (start < n - 1 && turns[start].role == ChatRole.assistant) start++;
    return turns.sublist(start);
  }
}
