import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'src/i18n.dart';
import 'src/library.dart';
import 'src/library_scope.dart';
import 'src/open_with.dart';
import 'src/pages/bookshelf_page.dart';
import 'src/pages/reader_page.dart';
import 'src/scan.dart';
import 'src/screen.dart';
import 'src/speech_media.dart';
import 'src/widgets.dart';

final _navigator = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppText.load();
  final library = LibraryController();
  await library.load();
  await applyScreenTurn(library.screenTurn);
  String? startBook;
  if (Platform.isAndroid) {
    await initSpeechMedia(channelName: AppText.get(library.uiLanguage, 'speech.channel'));
    startBook = await listenForOpenedBooks((path) => _openBook(library, path));
  }
  AppLifecycleListener(
    onPause: () => unawaited(library.onPause()),
    onResume: library.onResume,
  );
  runApp(EpubReaderApp(library: library));
  if (startBook != null) {
    final path = startBook;
    WidgetsBinding.instance.addPostFrameCallback((_) => _openBook(library, path));
  } else if (library.openLast && library.readingNow != null && library.bookByPath(library.readingNow!) != null) {
    final path = library.readingNow!;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_navigator.currentState?.push(stillRoute<void>(ReaderPage(path: path))));
    });
  }
}

/// A book from another app joins the shelf, then opens on top of it.
void _openBook(LibraryController library, String path) {
  library.addOpenedFile(path);
  final navigator = _navigator.currentState;
  if (navigator == null) return;
  navigator.popUntil((route) => route.isFirst);
  unawaited(navigator.push(stillRoute<void>(ReaderPage(path: canonicalPath(path)))));
}

class EpubReaderApp extends StatelessWidget {
  const EpubReaderApp({required this.library, super.key});

  final LibraryController library;

  @override
  Widget build(BuildContext context) {
    return LibraryScope(
      controller: library,
      child: MaterialApp(
        title: 'T Reader',
        navigatorKey: _navigator,
        debugShowCheckedModeBanner: false,
        scrollBehavior: const StillScrollBehavior(),
        theme: themeFor(AppThemeKind.einkWhite),
        themeAnimationDuration: Duration.zero,
        themeAnimationCurve: Curves.linear,
        builder: (context, child) {
          return ListenableBuilder(
            listenable: library,
            builder: (context, _) {
              return Theme(
                data: themeFor(library.theme),
                child: child ?? const SizedBox.shrink(),
              );
            },
          );
        },
        home: const BookshelfPage(),
      ),
    );
  }
}
