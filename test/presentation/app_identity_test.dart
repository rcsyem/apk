import 'dart:io';
import 'package:flutter/material';
import 'package:flutter_test/flutter_test';
import 'package:local_ai_assistant/presentation/strings_ar.dart';
import 'package:local_ai_assistant/presentation/settings/settings_screen.dart';
import 'package:local_ai_assistant/models/model_manager.dart';
import 'package:local_ai_assistant/models/download_manager.dart';
import 'package:local_ai_assistant/settings/app_settings.dart';
import 'package:local_ai_assistant/database/chat_database.dart';
import 'package:provider/provider.dart';
import '../mocks/fake_engine.dart';

void main() {
  group('v0.4.10 App Identity & Developer Credit Tests', () {
    test('verifies official Arabic app name is «بسيط»', () {
      expect(S.appName, equals('بسيط'));
    });

    test('verifies developer credit and about app text match official specifications', () {
      expect(S.aboutSectionTitle, equals('حول التطبيق'));
      expect(
        S.developerCredit,
        equals('تم بناء وتطوير هذا التطبيق من قبل الباحث الأمني رفيق مجلي.'),
      );
      expect(
        S.aboutAppDescription,
        contains('بسيط — مساعد ذكاء اصطناعي يعمل محلياً على جهازك.'),
      );
      expect(
        S.aboutAppDescription,
        contains('تم بناء وتطوير هذا التطبيق من قبل الباحث الأمني رفيق مجلي.'),
      );
    });

    test('verifies AndroidManifest.xml reflects new app name and icon', () async {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(await manifestFile.exists(), isTrue);
      final content = await manifestFile.readAsString();
      expect(content.contains('android:label="بسيط"'), isTrue);
      expect(content.contains('android:icon="@mipmap/ic_launcher"'), isTrue);
      expect(content.contains('android:roundIcon="@mipmap/ic_launcher_round"'), isTrue);
    });

    testWidgets('verifies Settings screen displays About section and developer credit', (tester) async {
      final engine = FakeEngine();
      final db = ChatDatabase(inMemory: true);
      await db.init();
      final mm = ModelManager(engine: engine, db: db);
      await mm.init();
      final dm = DownloadManager();
      final settings = AppSettings();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: mm),
            ChangeNotifierProvider.value(value: dm),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: const MaterialApp(
            home: SettingsScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(S.aboutSectionTitle), findsOneWidget);
      expect(find.text(S.aboutAppDescription), findsOneWidget);

      await db.close();
    });
  });
}
