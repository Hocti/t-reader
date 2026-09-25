import 'package:epub_reader/main.dart';
import 'package:epub_reader/src/i18n.dart';
import 'package:epub_reader/src/library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('empty bookshelf points at settings and can switch view', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppText.load();
    final library = LibraryController();
    await library.load();
    await tester.pumpWidget(EpubReaderApp(library: library));

    expect(find.textContaining('還沒有目錄'), findsOneWidget);
    expect(find.bySemanticsLabel('列表'), findsOneWidget);
    expect(find.textContaining('使用中'), findsNothing);

    await tester.tap(find.byIcon(Icons.grid_view));
    await tester.pump();
    expect(library.view, ShelfView.grid);

    await tester.tap(find.byIcon(Icons.update));
    await tester.pump();
    expect(library.sort, ShelfSort.modified);

    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pump();
    await tester.tap(find.text('已完結'));
    await tester.pump();
    expect(library.filter, ShelfFilter.finished);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('書的目錄'), findsOneWidget);
    expect(find.text('白'), findsOneWidget);
    expect(find.text('介面語言'), findsOneWidget);
    expect(find.textContaining('使用中'), findsNothing);

    await tester.tap(find.text('淺色'));
    await tester.pump();
    expect(library.theme.name, 'light');

    final page = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('閱讀時螢幕不休眠'), 200, scrollable: page);
    expect(library.openLast, isTrue);
    await tester.scrollUntilVisible(find.text('連接 Google Drive'), 200, scrollable: page);
    await tester.scrollUntilVisible(find.text('目前版本'), 200, scrollable: page);

    await tester.scrollUntilVisible(find.text('English'), -200, scrollable: page);
    await tester.tap(find.text('English'));
    await tester.pump();
    expect(library.uiLanguage, 'en');
    expect(find.text('Language'), findsOneWidget);
  });
}
