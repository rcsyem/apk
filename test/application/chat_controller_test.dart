import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/application/chat_controller.dart';
import 'package:local_ai_assistant/data/models.dart';
import 'package:local_ai_assistant/engine/inference_engine.dart';
import 'package:local_ai_assistant/presentation/strings_ar.dart';
import '../helpers/fakes.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  group('v0.4.7 Core Stability Tests', () {
    // 1. فتح التطبيق دون وجود نموذج
    test('1. فتح التطبيق دون وجود نموذج: حالة noModel وتعطيل الإرسال', () async {
      await env.settings.setActiveModelId(null);
      expect(env.models.active, isNull);
      expect(env.chat.state, ChatUiState.noModel);
      expect(env.chat.canSend, isFalse);
    });

    // 2. محاولة إرسال رسالة دون نموذج
    test('2. محاولة إرسال رسالة دون نموذج: عدم حفظ الرسالة وعرض إشعار', () async {
      await env.settings.setActiveModelId(null);
      await env.chat.send('رسالة بدون نموذج');
      expect(env.chat.messages, isEmpty);
      expect(env.chat.notice, isNotNull);
      expect(env.chat.state, ChatUiState.noModel);
      expect(env.chat.generating, isFalse);
    });

    // 3. تفعيل الواجهة عند وجود نموذج جاهز
    test('3. تفعيل الواجهة عند وجود نموذج جاهز: حالة ready وتمكين الإرسال', () async {
      await env.settings.setActiveModelId('m1');
      expect(env.models.active?.id, 'm1');
      expect(env.chat.state, ChatUiState.ready);
      expect(env.chat.canSend, isTrue);
    });

    // 4. فشل تحميل النموذج
    test('4. فشل تحميل النموذج: إظهار الخطأ وعدم حفظ رسالة كمرسلة وعدم تعليق الواجهة', () async {
      env.engine.failLoadWith = EngineException(EngineErrorCode.outOfMemory);
      await env.chat.send('مرحبا');
      expect(env.chat.notice, contains('الذاكرة'));
      expect(env.chat.generating, isFalse);
      expect(env.models.loading, isFalse);
      expect(env.chat.state, ChatUiState.error);
      expect(env.chat.messages, isEmpty);
    });

    // 5. حذف محادثة واحدة بعد التأكيد
    test('5. حذف محادثة واحدة بعد التأكيد: تحديث القائمة ومسح الرسائل بالتتالي', () async {
      await env.chat.send('المحادثة الأولى');
      final firstConv = env.chat.current!;
      await env.chat.newConversation();
      await env.chat.send('المحادثة الثانية');
      expect(env.chat.conversations.length, 2);

      final ok = await env.chat.delete(firstConv);
      expect(ok, isTrue);
      expect(env.chat.conversations.length, 1);
      expect(env.chat.conversations.any((c) => c.id == firstConv.id), isFalse);
      expect(await env.chatRepo.messages(firstConv.id), isEmpty);
    });

    // 6. إلغاء عملية الحذف
    test('6. إلغاء عملية الحذف: بقاء المحادثة والرسائل دون تغيير', () async {
      await env.chat.send('محادثة لن تُحذف');
      final conv = env.chat.current!;
      expect(env.chat.conversations.any((c) => c.id == conv.id), isTrue);
      expect((await env.chatRepo.messages(conv.id)).isNotEmpty, isTrue);
    });

    // 7. حذف جميع المحادثات بعد التأكيد
    test('7. حذف جميع المحادثات بعد التأكيد: مسح السجل وتحديث الحالة', () async {
      await env.chat.send('محادثة 1');
      await env.chat.newConversation();
      await env.chat.send('محادثة 2');
      expect(env.chat.conversations.length, 2);

      final ok = await env.chat.deleteAll();
      expect(ok, isTrue);
      expect(env.chat.conversations, isEmpty);
      expect(env.chat.messages, isEmpty);
      expect(env.chat.current, isNull);
      expect(await env.chatRepo.listConversations(), isEmpty);
    });

    // 8. إلغاء حذف جميع المحادثات
    test('8. إلغاء حذف جميع المحادثات: بقاء المحادثات دون تغيير', () async {
      await env.chat.send('محادثة باقية');
      expect(env.chat.conversations.isNotEmpty, isTrue);
      expect(await env.chatRepo.listConversations(), isNotEmpty);
    });

    // 9. إنشاء محادثة جديدة وتسميتها
    test('9. إنشاء محادثة جديدة وتسميتها: التسمية التلقائية من أول رسالة وتجنب التكرار', () async {
      await env.chat.newConversation();
      expect(env.chat.current?.title, S.defaultConversationTitle);

      await env.chat.send('ما هي فوائد التعلم الآلي المحلي؟');
      expect(env.chat.current?.title, contains('ما هي فوائد التعلم'));

      final originalTitle = env.chat.current!.title;
      await env.chat.send('هل يحافظ على الخصوصية؟');
      expect(env.chat.current?.title, originalTitle);
    });

    // 10. إعادة تشغيل التطبيق والتحقق من بقاء المحادثات
    test('10. إعادة تشغيل التطبيق والتحقق من بقاء المحادثات', () async {
      await env.chat.send('سؤال مهم جداً');
      final convId = env.chat.current!.id;

      final restartChat = ChatController(env.chatRepo, env.engine, env.models, env.settings);
      await restartChat.init();

      expect(restartChat.conversations.any((c) => c.id == convId), isTrue);
      expect(restartChat.messages.length, 2);
      expect(restartChat.messages.first.content, 'سؤال مهم جداً');
      restartChat.dispose();
    });

    // 11. إيقاف التوليد والتحقق من حفظ النص الجزئي
    test('11. إيقاف التوليد والتحقق من حفظ النص الجزئي كـ interrupted', () async {
      env.engine.script = List.generate(100, (i) => 'كلمة$i ');
      env.engine.pieceDelay = const Duration(milliseconds: 5);
      final f = env.chat.send('اكتب نصاً طويلاً');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await env.chat.stop();
      await f;

      final last = env.chat.messages.last;
      expect(last.role, MessageRole.assistant);
      expect(last.status, MessageStatus.interrupted);
      expect(last.content.isNotEmpty, isTrue);
      expect(last.content.length < 100 * 6, isTrue);
    });

    // 12. التأكد من عدم فقدان المحادثات بعد فشل التحميل
    test('12. التأكد من عدم فقدان المحادثات بعد فشل التحميل', () async {
      await env.chat.send('محادثة سابقة مكتملة');
      expect(env.chat.messages.length, 2);

      // تفريغ النموذج لمحاكاة محاولة تحميل فاشلة جديدة
      await env.models.unload();
      env.engine.failLoadWith = EngineException(EngineErrorCode.modelCorrupt);
      await env.chat.send('سؤال يواجه فشلاً في التحميل');

      // المحادثات والرسائل السابقة لا تُمس
      expect(env.chat.messages.length, 2);
      expect(env.chat.messages.first.content, 'محادثة سابقة مكتملة');
      expect(env.chat.notice, contains('تالف'));
    });
  });

  group('Additional Engine & Generation Safety Tests', () {
    test('منع الحذف أثناء التوليد', () async {
      env.engine.script = List.generate(100, (i) => 'نص$i ');
      env.engine.pieceDelay = const Duration(milliseconds: 20);
      final f = env.chat.send('توليد');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final deletedSingle = await env.chat.delete(env.chat.current!);
      expect(deletedSingle, isFalse);
      expect(env.chat.notice, contains('توليد'));

      final deletedAll = await env.chat.deleteAll();
      expect(deletedAll, isFalse);

      await env.chat.stop();
      await f;
    });

    test('follow-up keeps context: previous turns are passed to the engine', () async {
      await env.chat.send('الأول');
      await env.chat.send('الثاني');
      expect(env.engine.lastTurns.length, 3);
      expect(env.engine.lastTurns.first.role, ChatRole.user);
      expect(env.engine.lastTurns.last.content, 'الثاني');
    });

    test('engine failure mid-stream keeps earlier messages and the partial reply', () async {
      await env.chat.send('سؤال أول');
      env.engine.throwAfterFirstPiece = true;
      await env.chat.send('سؤال ثان');
      final m = env.chat.messages;
      expect(m.length, 4);
      expect(m[0].content, 'سؤال أول');
      expect(m[1].status, MessageStatus.complete);
      expect(m[3].status, MessageStatus.failed);
      expect(m[3].content, 'مرحبا');
      expect(env.chat.notice, isNotNull);
    });

    test('background stops generation, persists, then unloads the model', () async {
      env.engine.script = List.generate(100, (i) => 'ك$i ');
      env.engine.pieceDelay = const Duration(milliseconds: 5);
      final f = env.chat.send('اكتب');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await env.chat.onBackground();
      await f;
      expect(env.engine.log.contains('stop'), isTrue);
      expect(env.engine.log.contains('unload'), isTrue);
      expect(env.models.loadedId, isNull);
      final stored = await env.chatRepo.messages(env.chat.current!.id);
      expect(stored.last.status, MessageStatus.interrupted);
      expect(stored.last.content.isNotEmpty, isTrue);
    });

    test('a prompt that cannot fit gives a clear error and keeps context clean', () async {
      await env.settings.setContextLength(512);
      await env.chat.send('ا' * 5000);
      expect(env.chat.notice, contains('السياق'));
    });
  });
}
