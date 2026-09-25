import 'package:epub_reader/src/i18n.dart';
import 'package:epub_reader/src/library.dart';
import 'package:epub_reader/src/library_scope.dart';
import 'package:epub_reader/src/lookup.dart';
import 'package:epub_reader/src/lookup_sheet.dart';
import 'package:epub_reader/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shows the Chinese from the word list in a header that does not scroll', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppText.load();
    final library = LibraryController();
    await tester.runAsync(() async {
      await library.load();
      await WordDictionary.load();
    });
    var said = 0;
    var closed = 0;
    await tester.pumpWidget(
      LibraryScope(
        controller: library,
        child: MaterialApp(
          theme: themeFor(AppThemeKind.einkWhite),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: 300,
                child: LookupSheet(word: 'went,', onClose: () => closed++, onSay: () => said++),
              ),
            ),
          ),
        ),
      ),
    );
    // The test binding answers every HTTP request with 400, so this also covers the offline path.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();

    expect(find.text('went'), findsOneWidget);
    expect(find.text('原形 go'), findsOneWidget);
    expect(find.textContaining('vi.離去'), findsWidgets);

    final header = tester.getTopLeft(find.text('went'));
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -200));
    await tester.pump();
    expect(tester.getTopLeft(find.text('went')), header);

    await tester.tap(find.bySemanticsLabel('讀出字音'));
    await tester.tap(find.text('關閉'));
    expect(said, 1);
    expect(closed, 1);
  });
}
