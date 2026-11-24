// NOT EXECUTED (no Dart in the authoring sandbox). Run: flutter test
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/application/context_builder.dart';
import 'package:local_ai_assistant/engine/inference_engine.dart';

Future<int> _count(List<ChatTurn> t) async => t.fold<int>(0, (a, x) => a + x.content.length);

List<ChatTurn> _hist(List<String> texts) => [
      for (var i = 0; i < texts.length; i++)
        ChatTurn(i.isEven ? ChatRole.user : ChatRole.assistant, texts[i])
    ];

void main() {
  test('keeps everything when it fits', () async {
    final h = _hist(['aaaa', 'bbbb', 'cccc']);
    final r = await ContextBuilder.fit(h, budgetTokens: 100, count: _count);
    expect(r.length, 3);
  });

  test('drops the OLDEST messages first and keeps the newest', () async {
    final h = _hist(['11111', '22222', '33333', '44444', '55555']); // u a u a u
    final r = await ContextBuilder.fit(h, budgetTokens: 10, count: _count);
    expect(r.last.content, '55555');
    expect(r.every((t) => h.contains(t)), isTrue);
    expect(await _count(r) <= 10, isTrue);
  });

  test('never starts with a dangling assistant reply', () async {
    final h = _hist(['11111', '22222', '33333', '44444', '55555']);
    // budget fits exactly the last 3 messages (a u? -> indices 2..4 = u a u)
    final r = await ContextBuilder.fit(h, budgetTokens: 15, count: _count);
    expect(r.first.role, ChatRole.user);
  });

  test('throws when the newest message alone does not fit', () async {
    final h = _hist(['x', 'y' * 50]);
    expect(() => ContextBuilder.fit(h, budgetTokens: 10, count: _count),
        throwsA(isA<ContextTooSmallException>()));
  });

  test('empty history is returned as is', () async {
    expect(await ContextBuilder.fit(const [], budgetTokens: 1, count: _count), isEmpty);
  });
}
