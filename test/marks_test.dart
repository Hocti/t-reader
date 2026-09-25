import 'dart:convert';
import 'dart:io';

import 'package:epub_reader/src/book_data.dart';
import 'package:epub_reader/src/book_text.dart';
import 'package:epub_reader/src/library.dart';
import 'package:epub_reader/src/pages/reader_page.dart';
import 'package:epub_reader/src/reader_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('chapter starts follow the weights', () {
    expect(chapterStarts(weights: [100, 300, 600], chapterCount: 3), [0, 0.1, 0.4]);
    expect(chapterStarts(weights: null, chapterCount: 4), [0, 0.25, 0.5, 0.75]);
  });

  test('a chapter start pulls a spot that is close enough', () {
    const starts = [0.0, 0.1, 0.4];
    expect(snapChapter(starts, 0.105, 0.01), 1);
    expect(snapChapter(starts, 0.2, 0.01), isNull);
    expect(snapChapter(starts, 0.395, 0.01), 2);
  });

  test('highlights keep character offsets, and old ones cover whole sentences', () async {
    SharedPreferences.setMockInitialValues({
      'reader_v1': jsonEncode({
        'marks': {
          'book': [
            {'chapter': 1, 'start': 3, 'end': 3, 'text': '舊的'},
          ],
        },
      }),
    });
    final store = ReaderStore();
    await store.load();
    final old = store.legacyMarks('book').single;
    expect(old.startOffset, 0);
    expect(old.endOffset, isNull);
    await store.dropLegacy('book');
    final again = ReaderStore();
    await again.load();
    expect(again.legacyMarks('book'), isEmpty);
  });

  test('highlights, tags, and the reading place go to one file per book title', () async {
    final root = Directory.systemTemp.createTempSync('book-data');
    addTearDown(() => root.deleteSync(recursive: true));
    SharedPreferences.setMockInitialValues({
      'library_v1': jsonEncode({'dataDir': root.path}),
    });
    final library = LibraryController();
    await library.load();
    await library.openData(
      '/books/a.epub',
      title: '電玩的本質',
      legacyTags: const [BookTag(id: 1, chapter: 2, name: '第三章', sentenceId: 7)],
    );
    final mark = HighlightMark(
      chapter: 1,
      start: 4,
      end: 4,
      text: '字',
      startOffset: 2,
      endOffset: 3,
      created: DateTime.utc(2026, 9, 25, 5, 0),
    );
    library.addMark('/books/a.epub', mark);
    library.updateTag('/books/a.epub', 1, library.tagsFor('/books/a.epub').single.renamed('重點'));
    await library.data.flush();
    final file = File(p.join(root.path, '電玩的本質.json'));
    expect(file.existsSync(), isTrue);
    final saved = BookData.decode(file.readAsStringSync())!;
    expect(saved.marks.single.startOffset, 2);
    expect(saved.marks.single.created, DateTime.utc(2026, 9, 25, 5, 0));
    expect(saved.tags.single.name, '重點');
    library.removeMarks('/books/a.epub', [mark]);
    library.updateTag('/books/a.epub', 1, null);
    await library.data.flush();
    final emptied = BookData.decode(file.readAsStringSync())!;
    expect(emptied.marks, isEmpty);
    expect(emptied.tags, isEmpty);
    expect(emptied.removed.keys, containsAll([mark.key, 't1']));
    library.dispose();
  });

  test('merging keeps the later place, both sides\' highlights, removals, and the newer tag name', () {
    final phone = BookData('書')
      ..chapter = 3
      ..lastRead = DateTime.utc(2026, 9, 1)
      ..marks = [HighlightMark(chapter: 0, start: 1, end: 1, text: '甲', created: DateTime.utc(2026, 1, 1))]
      ..tags = [BookTag(id: 10, chapter: 0, name: '舊名')];
    final tablet = BookData('書')
      ..chapter = 5
      ..lastRead = DateTime.utc(2026, 9, 2)
      ..marks = [HighlightMark(chapter: 0, start: 2, end: 2, text: '乙', created: DateTime.utc(2026, 1, 2))]
      ..tags = [BookTag(id: 10, chapter: 0, name: '新名', updated: DateTime.utc(2026, 5, 1))]
      ..removed = {phone.marks.single.key: DateTime.utc(2026, 9, 2)};
    final merged = BookData.merge(phone, tablet);
    expect(merged.chapter, 5);
    expect(merged.marks.map((mark) => mark.text), ['乙']);
    expect(merged.tags.single.name, '新名');
    expect(BookData.merge(tablet, phone).encode(), merged.encode());
    expect(BookData.decode(merged.encode())!.encode(), merged.encode());
  });

  test('a selection that touches a highlight finds it, one that only meets its end does not', () {
    const mark = HighlightMark(chapter: 0, start: 2, end: 3, text: 'x', startOffset: 5, endOffset: 4);
    List<HighlightMark> hit(int s1, int o1, int s2, int o2) =>
        marksOverlapping([mark], chapter: 0, startSid: s1, startOffset: o1, endSid: s2, endOffset: o2);
    expect(hit(2, 0, 2, 6), [mark]);
    expect(hit(3, 3, 4, 0), [mark]);
    expect(hit(2, 0, 2, 5), isEmpty);
    expect(hit(3, 4, 3, 9), isEmpty);
    expect(marksOverlapping([mark], chapter: 1, startSid: 2, startOffset: 0, endSid: 3, endOffset: 9), isEmpty);
    const whole = HighlightMark(chapter: 0, start: 7, end: 7, text: 'y');
    expect(marksOverlapping([whole], chapter: 0, startSid: 7, startOffset: 40, endSid: 7, endOffset: 41), [whole]);
  });

  test('a title becomes a safe file name', () {
    expect(bookDataFileName('電玩的本質'), '電玩的本質.json');
    expect(bookDataFileName('A/B: "C"?'), 'A_B_ _C__.json');
    expect(bookDataFileName('  '), 'untitled.json');
    expect(bookDataFileName('.hidden'), 'hidden.json');
  });

  test('images are listed in page order, including SVG images', () {
    const html = '<body><div id="reader-viewport"><div id="reader-flow">'
        '<img src="a.jpg"/><svg><image xlink:href="../b.png" width="1"/></svg><img alt="x"/><img src=\'c&amp;d.gif\'/>'
        '</div></div></body>';
    expect(imageSources(html), ['a.jpg', '../b.png', null, 'c&d.gif']);
  });

  test('the column choice is saved', () {
    const layout = ReaderLayout(columns: ColumnMode.double);
    expect(ReaderLayout.fromJson(layout.toJson()).columns, ColumnMode.double);
    expect(ReaderLayout.fromJson(const {}).columns, ColumnMode.single);
  });

  test('wikipedia search picks the language from the text', () {
    expect(wikiSearchUrl('香港').host, 'zh.wikipedia.org');
    expect(wikiSearchUrl('香港').path, '/zh-hk/Special:Search');
    expect(wikiSearchUrl('Hong Kong').host, 'en.wikipedia.org');
    expect(googleSearchUrl('a b').queryParameters['q'], 'a b');
  });
}
