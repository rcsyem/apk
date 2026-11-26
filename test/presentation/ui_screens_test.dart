import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:local_ai_assistant/application/app_settings.dart';
import 'package:local_ai_assistant/application/chat_controller.dart';
import 'package:local_ai_assistant/models/download_manager.dart';
import 'package:local_ai_assistant/models/model_importer.dart';
import 'package:local_ai_assistant/models/model_manager.dart';
import 'package:local_ai_assistant/native/native_info.dart';
import 'package:local_ai_assistant/data/model_repository.dart';
import 'package:local_ai_assistant/presentation/home/home_screen.dart';
import 'package:local_ai_assistant/presentation/chat/conversations_screen.dart';
import 'package:local_ai_assistant/presentation/chat/chat_screen.dart';
import 'package:local_ai_assistant/presentation/settings/settings_screen.dart';
import 'package:local_ai_assistant/presentation/main_navigation_screen.dart';
import 'package:local_ai_assistant/presentation/strings_ar.dart';
import 'package:local_ai_assistant/presentation/utils/date_formatter.dart';
import '../helpers/fakes.dart';

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
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
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
  group('ArabicDateFormatter Tests', () {
    test('formats today and yesterday correctly', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day, 14, 30);
      expect(ArabicDateFormatter.format(today), contains('اليوم 14:30'));

      final yesterday = now.subtract(const Duration(days: 1));
      final yesterdayDt = DateTime(yesterday.year, yesterday.month, yesterday.day, 9, 15);
      expect(ArabicDateFormatter.format(yesterdayDt), contains('أمس 09:15'));
    });

    test('formats older dates with YYYY/MM/DD', () {
      final old = DateTime(2025, 5, 20, 10, 0);
      expect(ArabicDateFormatter.format(old), '2025/05/20');
    });

    test('formats time string', () {
      final dt = DateTime(2026, 1, 1, 8, 5);
      expect(ArabicDateFormatter.formatTime(dt), '08:05');
    });
  });

  group('v0.4.9 UI Screens Widget Tests', () {
    late TestEnv env;

    setUp(() async {
      env = await TestEnv.create();
    });

    tearDown(() async {
      await env.dispose();
    });

    testWidgets('HomeScreen renders model card and elements', (tester) async {
      await tester.pumpWidget(createTestApp(
        env,
        HomeScreen(onNavigateToTab: (_) {}),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(S.appName), findsOneWidget);
      expect(find.text(S.activeModel), findsOneWidget);
      expect(find.text(S.startNewChatAction), findsOneWidget);
      expect(find.text(S.localAiBadge), findsOneWidget);
    });

    testWidgets('ConversationsScreen displays empty state', (tester) async {
      await tester.pumpWidget(createTestApp(
        env,
        ConversationsScreen(onNavigateToChat: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(S.conversations), findsOneWidget);
      expect(find.text(S.noRecentConversations), findsOneWidget);
      expect(find.text(S.newChat), findsOneWidget);
    });

    testWidgets('MainNavigationScreen renders destinations and switches tabs', (tester) async {
      await tester.pumpWidget(createTestApp(
        env,
        const MainNavigationScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(S.home), findsOneWidget);
      expect(find.text(S.chat), findsOneWidget);
      expect(find.text(S.conversations), findsOneWidget);
      expect(find.text(S.settings), findsOneWidget);

      // Tap Chat destination
      await tester.tap(find.text(S.chat));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(S.emptyChat), findsOneWidget);
    });

    testWidgets('ChatScreen renders empty state and suggestions', (tester) async {
      await tester.pumpWidget(createTestApp(
        env,
        const ChatScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(S.emptyChat), findsOneWidget);
      expect(find.text(S.suggestionsTitle), findsOneWidget);
      expect(find.text(S.suggestion1), findsOneWidget);
    });

    testWidgets('SettingsScreen renders active model section and parameters', (tester) async {
      await tester.pumpWidget(createTestApp(
        env,
        const SettingsScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(S.settings), findsOneWidget);
      expect(find.text(S.installedModels), findsOneWidget);
      expect(find.text(S.importGguf), findsOneWidget);
    });

    testWidgets('ConversationsScreen starts a new chat and triggers navigation', (tester) async {
      var navigated = false;
      await tester.pumpWidget(createTestApp(
        env,
        ConversationsScreen(onNavigateToChat: () => navigated = true),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      final newChatBtn = find.text(S.newChat);
      expect(newChatBtn, findsOneWidget);
      await tester.tap(newChatBtn);
      await tester.pump(const Duration(milliseconds: 100));

      expect(navigated, isTrue);
      expect(env.chat.current, isNotNull);
    });

    testWidgets('ConversationsScreen opens an existing conversation and triggers navigation', (tester) async {
      await env.chat.send('محادثة سابقة للتجربة');
      final conv = env.chat.current!;
      var navigated = false;

      await tester.pumpWidget(createTestApp(
        env,
        ConversationsScreen(onNavigateToChat: () => navigated = true),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(conv.title), findsOneWidget);
      await tester.tap(find.text(conv.title));
      await tester.pump(const Duration(milliseconds: 100));

      expect(navigated, isTrue);
      expect(env.chat.current?.id, conv.id);
    });

    testWidgets('ConversationsScreen deletes conversation with confirmation dialog', (tester) async {
      await env.chat.send('محادثة للحذف');
      final conv = env.chat.current!;

      await tester.pumpWidget(createTestApp(
        env,
        ConversationsScreen(onNavigateToChat: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(conv.title), findsOneWidget);

      final deleteBtn = find.byTooltip(S.deleteChat).first;
      await tester.tap(deleteBtn);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text(S.confirmDeleteChatTitle), findsOneWidget);
      expect(find.text(S.delete), findsOneWidget);

      await tester.tap(find.text(S.delete));
      await tester.pump(const Duration(milliseconds: 200));

      expect(env.chat.conversations.any((c) => c.id == conv.id), isFalse);
    });

    testWidgets('ConversationsScreen prevents deletion during generation', (tester) async {
      await env.chat.send('محادثة جارية');
      final conv = env.chat.current!;

      env.engine.script = List.generate(100, (i) => 'كلمة$i ');
      env.engine.pieceDelay = const Duration(milliseconds: 50);
      final genFuture = env.chat.send('توليد مستمر');
      await Future<void>.delayed(const Duration(milliseconds: 60));

      await tester.pumpWidget(createTestApp(
        env,
        ConversationsScreen(onNavigateToChat: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      final deleteBtn = find.byTooltip(S.deleteChat).first;
      await tester.tap(deleteBtn);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(S.cannotDeleteWhileGenerating), findsOneWidget);
      expect(find.text(S.confirmDeleteChatTitle), findsNothing);

      await env.chat.stop();
      await genFuture;
    });

    testWidgets('ChatScreen stop generation button stops stream and preserves partial text', (tester) async {
      env.engine.script = List.generate(50, (i) => 'نص$i ');
      env.engine.pieceDelay = const Duration(milliseconds: 30);
      final genFuture = env.chat.send('ابدأ الكتابة');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await tester.pumpWidget(createTestApp(
        env,
        const ChatScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(S.generating), findsOneWidget);
      final stopBtn = find.text(S.stopGeneration);
      expect(stopBtn, findsOneWidget);

      await tester.tap(stopBtn);
      await tester.pump(const Duration(milliseconds: 100));
      await genFuture;

      final last = env.chat.messages.last;
      expect(last.content, isNotEmpty);
    });

    testWidgets('ChatScreen disables input and sends warning when no model is ready', (tester) async {
      await env.settings.setActiveModelId(null);

      await tester.pumpWidget(createTestApp(
        env,
        const ChatScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(S.noModelShortNotice), findsOneWidget);
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.enabled, isFalse);
    });

    testWidgets('ChatScreen shows loading indicator when model is loading', (tester) async {
      env.models.loading = true;

      await tester.pumpWidget(createTestApp(
        env,
        const ChatScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(S.modelLoadingMessage), findsOneWidget);
      env.models.loading = false;
    });

    testWidgets('ChatScreen displays error banner on notice', (tester) async {
      env.engine.failLoadWith = EngineException(EngineErrorCode.outOfMemory);
      await env.chat.send('فحص الخطأ');

      await tester.pumpWidget(createTestApp(
        env,
        const ChatScreen(),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(env.chat.notice, isNotNull);
      expect(find.text(env.chat.notice!), findsOneWidget);
    });

    testWidgets('Switching active model preserves all conversations and messages', (tester) async {
      await env.chat.send('محادثة مهمة أولى');
      expect(env.chat.conversations.length, 1);
      final convId = env.chat.current!.id;

      await env.models.switchModel('m1');

      expect(env.chat.conversations.length, 1);
      expect(env.chat.conversations.first.id, convId);
      expect(env.chat.messages.length, 2);
    });
  });
}
