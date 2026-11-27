import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/presentation/strings_ar.dart';

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

    test('verifies AndroidManifest.xml reflects new app name and icon configuration', () async {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(await manifestFile.exists(), isTrue);
      final content = await manifestFile.readAsString();
      expect(content.contains('android:label="بسيط"'), isTrue);
      expect(content.contains('android:icon="@mipmap/ic_launcher"'), isTrue);
      expect(content.contains('android:roundIcon="@mipmap/ic_launcher_round"'), isTrue);
      expect(content.contains('android:supportsRtl="true"'), isTrue);
    });

    test('verifies Android adaptive and density icon resources exist and are non-empty', () async {
      final colorsFile = File('android/app/src/main/res/values/colors.xml');
      expect(await colorsFile.exists(), isTrue);
      final colorsContent = await colorsFile.readAsString();
      expect(colorsContent.contains('#0D1B2A'), isTrue);

      final adaptiveLauncher = File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml');
      final adaptiveRound = File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml');
      expect(await adaptiveLauncher.exists(), isTrue);
      expect(await adaptiveRound.exists(), isTrue);

      const densities = ['mipmap-mdpi', 'mipmap-hdpi', 'mipmap-xhdpi', 'mipmap-xxhdpi', 'mipmap-xxxhdpi'];
      for (final d in densities) {
        final legacy = File('android/app/src/main/res/$d/ic_launcher.png');
        final round = File('android/app/src/main/res/$d/ic_launcher_round.png');
        final fg = File('android/app/src/main/res/$d/ic_launcher_foreground.png');
        expect(await legacy.exists(), isTrue, reason: '$d ic_launcher.png missing');
        expect(await legacy.length(), greaterThan(0));
        expect(await round.exists(), isTrue, reason: '$d ic_launcher_round.png missing');
        expect(await round.length(), greaterThan(0));
        expect(await fg.exists(), isTrue, reason: '$d ic_launcher_foreground.png missing');
        expect(await fg.length(), greaterThan(0));
      }
    });
  });
}
