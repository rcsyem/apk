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
      ChangeNotifierProvider<DownloadManager>(
        create: (_) => DownloadManager(
          modelsDir: env.dir,
          nativeInfo: env.native,
        ),
      ),
      Provider<ModelImporter>(
        create: (_) => ModelImporter(
          modelsDir: env.dir,
          nativeInfo: env.native,
          repo: env.modelRepo,
        ),
      ),
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
    testWidgets('HomeScreen renders model card and elements', (tester) async {
      final env = await TestEnv.create();
      try {
        await tester.pumpWidget(createTestApp(
          env,
          HomeScreen(onNavigateToTab: (_) {}),
        ));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text(S.appName), findsOneWidget);
        expect(find.text(S.activeModel), findsOneWidget);
        expect(find.text(S.startNewChatAction), findsOneWidget);
        expect(find.text(S.localAiBadge), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await env.dispose();
      }
    });

    testWidgets('ConversationsScreen displays empty state', (tester) async {
      final env = await TestEnv.create();
      try {
        await tester.pumpWidget(createTestApp(
          env,
          ConversationsScreen(onNavigateToChat: () {}),
        ));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text(S.conversations), findsOneWidget);
        expect(find.text(S.noRecentConversations), findsOneWidget);
        expect(find.text(S.newChat), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await env.dispose();
      }
    });

    testWidgets('MainNavigationScreen renders destinations and switches tabs', (tester) async {
      final env = await TestEnv.create();
      try {
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
      } finally {
        await tester.pumpWidget(const SizedBox());
        await env.dispose();
      }
    });

    testWidgets('ChatScreen shows disabled send notice and suggestions when no model', (tester) async {
      final env = await TestEnv.create(models: 0);
      try {
        await tester.pumpWidget(createTestApp(
          env,
          const ChatScreen(),
        ));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text(S.noModelShortNotice), findsOneWidget);
        expect(find.text(S.emptyChat), findsOneWidget);
        expect(find.text(S.suggestionsTitle), findsOneWidget);
        expect(find.text(S.suggestion1), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await env.dispose();
      }
    });
  });
}
