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
import 'package:local_ai_assistant/presentation/main_navigation_screen.dart';
import 'package:local_ai_assistant/presentation/strings_ar.dart';
import 'package:local_ai_assistant/presentation/utils/date_formatter.dart';
import '../helpers/fakes.dart';

Widget createTestApp(TestEnv env, Widget child) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppSettings>.value(value: env.settings),
      ChangeNotifierProvider<ModelManager>.value(value: env.models),
      ChangeNotifierProvider<ChatController>.value(value: env.chat),
      ChangeNotifierProvider<DownloadManager>.value(value: env.downloads),
      Provider<ModelImporter>.value(value: env.importer),
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
      env.dispose();
    });

    testWidgets('HomeScreen renders model card and start chat action', (tester) async {
      int navigatedTo = -1;
      await tester.pumpWidget(createTestApp(
        env,
        HomeScreen(onNavigateToTab: (idx) => navigatedTo = idx),
      ));
      await tester.pumpAndSettle();

      expect(find.text(S.appName), findsOneWidget);
      expect(find.text(S.activeModel), findsOneWidget);
      expect(find.text(S.startNewChatAction), findsOneWidget);
      expect(find.text(S.localAiBadge), findsOneWidget);

      // Tap start chat
      await tester.tap(find.text(S.startNewChatAction));
      await tester.pumpAndSettle();
      expect(navigatedTo, 1); // Chat tab
    });

    testWidgets('ConversationsScreen displays empty state and new chat button', (tester) async {
      bool chatNavigated = false;
      await tester.pumpWidget(createTestApp(
        env,
        ConversationsScreen(onNavigateToChat: () => chatNavigated = true),
      ));
      await tester.pumpAndSettle();

      expect(find.text(S.conversations), findsOneWidget);
      expect(find.text(S.noRecentConversations), findsOneWidget);
      expect(find.text(S.newChat), findsOneWidget);

      // Tap FAB
      await tester.tap(find.text(S.newChat));
      await tester.pumpAndSettle();
      expect(chatNavigated, true);
    });

    testWidgets('MainNavigationScreen has 4 destinations', (tester) async {
      await tester.pumpWidget(createTestApp(
        env,
        const MainNavigationScreen(),
      ));
      await tester.pumpAndSettle();

      expect(find.text(S.home), findsOneWidget);
      expect(find.text(S.chat), findsOneWidget);
      expect(find.text(S.conversations), findsOneWidget);
      expect(find.text(S.settings), findsOneWidget);

      // Tap Chat destination
      await tester.tap(find.text(S.chat));
      await tester.pumpAndSettle();
      expect(find.text(S.emptyChat), findsOneWidget);
    });

    testWidgets('ChatScreen shows disabled send when no model', (tester) async {
      await env.settings.setActiveModelId(null);
      await tester.pumpWidget(createTestApp(
        env,
        const ChatScreen(),
      ));
      await tester.pumpAndSettle();

      expect(find.text(S.noModelShortNotice), findsOneWidget);
      expect(find.text(S.emptyChat), findsOneWidget);
      expect(find.text(S.suggestionsTitle), findsOneWidget);

      // Suggestions are present
      expect(find.text(S.suggestion1), findsOneWidget);
    });
  });
}
