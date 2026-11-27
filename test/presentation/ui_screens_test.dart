import "package:flutter/material.dart";
import "package:flutter_localizations/flutter_localizations.dart";
import "package:flutter_test/flutter_test.dart";
import "package:provider/provider.dart";
import "package:local_ai_assistant/application/app_settings.dart";
import "package:local_ai_assistant/application/chat_controller.dart";
import "package:local_ai_assistant/data/models.dart";
import "package:local_ai_assistant/models/download_manager.dart";
import "package:local_ai_assistant/models/model_importer.dart";
import "package:local_ai_assistant/models/model_manager.dart";
import "package:local_ai_assistant/native/native_info.dart";
import "package:local_ai_assistant/data/model_repository.dart";
import "package:local_ai_assistant/presentation/home/home_screen.dart";
import "package:local_ai_assistant/presentation/chat/conversations_screen.dart";
import "package:local_ai_assistant/presentation/chat/chat_screen.dart";
import "package:local_ai_assistant/presentation/settings/settings_screen.dart";
import "package:local_ai_assistant/presentation/main_navigation_screen.dart";
import "package:local_ai_assistant/presentation/strings_ar.dart";
import "package:local_ai_assistant/presentation/utils/date_formatter.dart";
import "../helpers/fakes.dart";

Widget createTestApp(TestEnv env, Widget child) {
  final downloads = DownloadManager(
    modelsDir: env.dir,
    nativeInfo: env.native,
  );
  final importer = ModelImporter(
    modelsDir: env.dir,
    nativeInfo: env.native,
    repo: env.modelRepo,
  );

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppSettings>.value(value: env.settings),
      ChangeNotifierProvider<ModelManager>.value(value: env.models),
      ChangeNotifierProvider<ChatController>.value(value: env.chat),
      ChangeNotifierProvider<DownloadManager>.value(value: downloads),
      Provider<ModelImporter>.value(value: importer),
      Provider<ModelRepository>.value(value: env.modelRepo),
      Provider<NativeInfo>.value(value: env.native),
    ],
    child: MaterialApp(
      locale: const Locale("ar"),
      supportedLocales: const [Locale("ar")],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    ),
  );
}

void main() {
  group("ArabicDateFormatter Tests", () {
    test("formats today and yesterday correctly", () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 14, 30);
      expect(ArabicDateFormatter.format(today), contains("اليوم 14:30"));

      final yesterday = now.subtract(const Duration(days: 1));
      final yesterdayDt = DateTime(yesterday.year, yesterday.month, yesterday.day, 9, 15);
      expect(ArabicDateFormatter.format(yesterdayDt), contains("أمس 09:15"));
    });

    test("formats older dates with YYYY/MM/DD", () {
      final old = DateTime(2025, 5, 20, 10, 0);
      expect(ArabicDateFormatter.format(old), "2025/05/20");
    });

    test("formats time string", () {
      final dt = DateTime(2026, 1, 1, 8, 5);
      expect(ArabicDateFormatter.formatTime(dt), "08:05");
    });
  });

  group("v0.4.9 UI Screens Widget Tests", () {
    late TestEnv env;

    setUp(() async {
      env = await TestEnv.create();
    });

    tearDown(() async {
      await env.dispose();
    });

    testWidgets("HomeScreen renders model card and elements", (tester) async {
      await tester.pumpWidget(createTestApp(
        env,
        HomeScreen(onNavigateToTab: (_) {}),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(S.appName), findsOneWidget);
      expect(find.text(S.activeModel), findsOneWidget);
      expect(find.text(S.startNewChatAction), findsOneWidget);
      expect(find.text(S.localAiBadge), findsOneWidget);
    });

    testWidgets("ConversationsScreen displays empty state", (tester) async {
      await tester.pumpWidget(createTestApp(
        env,
        ConversationsScreen(onNavigateToChat: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(S.conversations), findsOneWidget);
      expect(find.text(S.noRecentConversations), findsOneWidget);
      expect(find.text(S.newChat), findsOneWidget);
    });

    testWidgets("MainNavigationScreen renders destinations and switches tabs", (tester) async {
      await tester.pumpWidget(createTestApp(
        env,
        const MainNavigationScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(S.home), findsOneWidget);
      expect(find.text(S.chat), findsOneWidget);
      expect(find.text(S.conversations), findsOneWidget);
      expect(find.text(S.settings), findsOneWidget);

      await tester.tap(find.text(S.chat));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(S.emptyChat), findsOneWidget);
    });

    testWidgets("ChatScreen renders empty state and suggestions", (tester) async {
      await tester.pumpWidget(createTestApp(
        env,
        const ChatScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(S.emptyChat), findsOneWidget);
      expect(find.text(S.suggestionsTitle), findsOneWidget);
      expect(find.text(S.suggestion1), findsOneWidget);
    });

    testWidgets("SettingsScreen renders active model section and parameters", (tester) async {
      await tester.pumpWidget(createTestApp(
        env,
        const SettingsScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(S.settings), findsOneWidget);
      expect(find.text(S.installedModels), findsOneWidget);
      expect(find.text(S.importGguf), findsOneWidget);
    });

    testWidgets("ChatScreen renders interrupted partial text message correctly", (tester) async {
      final c = await env.chatRepo.createConversation(title: "محادثة مجزأة");
      await env.chatRepo.addMessage(
        conversationId: c.id,
        role: MessageRole.assistant,
        content: "نص جزئي تم حفظه بعد الإيقاف",
        status: MessageStatus.interrupted,
      );
      await env.chat.open(c);

      await tester.pumpWidget(createTestApp(
        env,
        const ChatScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text("نص جزئي تم حفظه بعد الإيقاف"), findsOneWidget);
    });

    testWidgets("ChatScreen disables input when no model is ready", (tester) async {
      await env.settings.setActiveModelId(null);

      await tester.pumpWidget(createTestApp(
        env,
        const ChatScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(S.noModelShortNotice), findsOneWidget);
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.enabled, isFalse);
    });

    testWidgets("ChatScreen shows loading indicator when model is loading", (tester) async {
      env.models.loading = true;

      await tester.pumpWidget(createTestApp(
        env,
        const ChatScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text(S.modelLoadingMessage), findsOneWidget);
      env.models.loading = false;
    });

    testWidgets("ChatScreen displays error banner on notice", (tester) async {
      env.chat.notice = "تنبيه خطأ للتجربة";

      await tester.pumpWidget(createTestApp(
        env,
        const ChatScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(env.chat.notice, isNotNull);
      expect(find.text("تنبيه خطأ للتجربة"), findsOneWidget);
    });
  });

  group("v0.4.9 UI & Controller Behavioral Integration Tests", () {
    late TestEnv env;

    setUp(() async {
      env = await TestEnv.create();
    });

    tearDown(() async {
      await env.dispose();
    });

    test("بدء محادثة جديدة عبر ChatController وتحديث المحادثة الحالية", () async {
      await env.chat.newConversation();
      expect(env.chat.current, isNotNull);
      expect(env.chat.conversations.length, 1);
    });

    test("فتح محادثة سابقة واسترجاع رسائلها بدقة", () async {
      final conv = await env.chatRepo.createConversation(title: "محادثة قديمة");
      await env.chatRepo.addMessage(
        conversationId: conv.id,
        role: MessageRole.user,
        content: "سؤال قديم محفوظ",
      );
      await env.chat.init();

      await env.chat.open(conv);
      expect(env.chat.current?.id, conv.id);
      expect(env.chat.messages.length, 1);
      expect(env.chat.messages.first.content, "سؤال قديم محفوظ");
    });

    test("حذف محادثة بعد التأكيد يزيلها من القائمة وقاعدة البيانات", () async {
      final conv = await env.chatRepo.createConversation(title: "محادثة للحذف");
      await env.chat.init();
      expect(env.chat.conversations.any((c) => c.id == conv.id), isTrue);

      final deleted = await env.chat.delete(conv);
      expect(deleted, isTrue);
      expect(env.chat.conversations.any((c) => c.id == conv.id), isFalse);
    });

    test("منع حذف المحادثة أثناء التوليد النشط للحفاظ على سلامة البيانات", () async {
      final conv = await env.chatRepo.createConversation(title: "محادثة جارية");
      await env.chat.init();
      env.chat.setGeneratingForTesting(true);

      final deleted = await env.chat.delete(conv);
      expect(deleted, isFalse);
      expect(env.chat.notice, contains("لا يمكن حذف"));
      expect(env.chat.conversations.any((c) => c.id == conv.id), isTrue);

      env.chat.setGeneratingForTesting(false);
    });

    test("إيقاف التوليد يستدعي stop في المحرك ويحدّث حالة التوليد", () async {
      final conv = await env.chatRepo.createConversation(title: "محادثة إيقاف");
      await env.chat.open(conv);
      env.chat.setGeneratingForTesting(true);

      await env.chat.stop();
      expect(env.engine.log.contains("stop"), isTrue);
      expect(env.chat.generating, isFalse);
    });

    test("حفظ النص الجزئي بحالة interrupted في الرسائل", () async {
      final conv = await env.chatRepo.createConversation(title: "محادثة جزئية");
      await env.chatRepo.addMessage(
        conversationId: conv.id,
        role: MessageRole.assistant,
        content: "نص جزئي محفوظ بعد التوقف",
        status: MessageStatus.interrupted,
      );
      await env.chat.open(conv);
      expect(env.chat.messages.last.status, MessageStatus.interrupted);
      expect(env.chat.messages.last.content, "نص جزئي محفوظ بعد التوقف");
    });

    test("تعطيل الإرسال وحالة canSend = false عند غياب النموذج", () async {
      await env.settings.setActiveModelId(null);
      expect(env.chat.canSend, isFalse);
    });

    test("تغيير النموذج النشط يحافظ على سجل المحادثات والرسائل", () async {
      final conv = await env.chatRepo.createConversation(title: "محادثة مهمة أولى");
      await env.chatRepo.addMessage(
        conversationId: conv.id,
        role: MessageRole.user,
        content: "سؤال المستخدم",
      );
      await env.chat.init();
      expect(env.chat.conversations.length, 1);

      await env.models.switchModel("m1");

      expect(env.chat.conversations.length, 1);
      expect(env.chat.conversations.first.id, conv.id);
    });
  });
}
