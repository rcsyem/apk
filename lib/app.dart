import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'application/chat_controller.dart';
import 'native/native_info.dart';
import 'presentation/main_navigation_screen.dart';
import 'presentation/strings_ar.dart';

/// Android ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL.
const int kTrimRunningCritical = 15;

class LocalAiApp extends StatefulWidget {
  const LocalAiApp({super.key});
  @override
  State<LocalAiApp> createState() => _LocalAiAppState();
}

class _LocalAiAppState extends State<LocalAiApp> with WidgetsBindingObserver {
  StreamSubscription<int>? _trimSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final native = context.read<NativeInfo>();
    final chat = context.read<ChatController>();
    _trimSub = native.trimMemoryLevels.listen((level) {
      if (level >= kTrimRunningCritical) {
        chat.onBackground();
      }
    });
  }

  @override
  void dispose() {
    _trimSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      context.read<ChatController>().onBackground();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: S.appName,
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        scaffoldBackgroundColor: const Color(0xFFF9FAF9),
        cardTheme: CardTheme(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 1,
        ),
        navigationBarTheme: NavigationBarThemeData(
          indicatorColor: Colors.teal.shade100,
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      home: const MainNavigationScreen(),
    );
  }
}
