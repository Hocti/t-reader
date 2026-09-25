import 'dart:io';

import 'package:epub_reader/src/book_text.dart';
import 'package:epub_reader/src/i18n.dart';
import 'package:epub_reader/src/library.dart';
import 'package:epub_reader/src/scan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  setUp(() {
    AppText.loadString(File('assets/i18n/strings.csv').readAsStringSync());
  });

  test('format and empty shelf copy', () {
    expect(formatReadTime(null), isNull);
    expect(formatReadTime(DateTime(2026, 9, 23, 14, 5)), '2026-09-23 14:05');
    expect(AppText.get('zh-Hant', 'shelf.unread'), '尚未閱讀');
    expect(
      emptyShelfNotice(
        directories: 0,
        books: 0,
        visible: 0,
        missing: 0,
        unreadable: 0,
      )?.key,
      'shelf.empty_no_dir',
    );
    expect(AppText.get('en', 'shelf.empty_no_dir'), contains('settings icon'));
    expect(
      emptyShelfNotice(
        directories: 1,
        books: 0,
        visible: 0,
        missing: 0,
        unreadable: 0,
      )?.key,
      'shelf.empty_one',
    );
    expect(
      emptyShelfNotice(
        directories: 1,
        books: 2,
        visible: 0,
        missing: 0,
        unreadable: 0,
      )?.key,
      'shelf.empty_filtered',
    );
  });

  test('sort puts the latest read book first', () {
    final older = ShelfBook(path: '/a', zipped: true, fallbackTitle: '甲');
    older.lastRead = DateTime(2026, 1, 1);
    final newer = ShelfBook(path: '/b', zipped: true, fallbackTitle: '乙');
    newer.lastRead = DateTime(2026, 2, 1);
    final unread = ShelfBook(path: '/c', zipped: false, fallbackTitle: '丙');
    final sorted = [older, unread, newer]..sort((a, b) => compareBooks(a, b, ShelfSort.lastRead));
    expect(sorted.map((book) => book.fallbackTitle), ['乙', '甲', '丙']);
  });

  test('modified sort puts the newest file first', () {
    final older = ShelfBook(path: '/a', zipped: true, fallbackTitle: '甲');
    older.modified = DateTime(2020, 1, 1);
    final newer = ShelfBook(path: '/b', zipped: false, fallbackTitle: '乙');
    newer.modified = DateTime(2024, 6, 1);
    final sorted = [older, newer]..sort((a, b) => compareBooks(a, b, ShelfSort.modified));
    expect(sorted.map((book) => book.fallbackTitle), ['乙', '甲']);
  });

  test('progress uses the saved estimate, else the chapter start', () {
    final book = ShelfBook(path: '/a.epub', zipped: true, fallbackTitle: '甲');
    expect(book.progress, 0);
    expect(progressLabel(book), isNull);
    book.chapterCount = 10;
    book.chapterIndex = 3;
    expect(book.progress, 0.3);
    book.readProgress = 0.375;
    expect(progressLabel(book), '37%');
  });

  test('a directory scan keeps one epub and one unzipped book', () {
    final root = Directory.systemTemp.createTempSync('epub-scan');
    addTearDown(() => root.deleteSync(recursive: true));
    File(p.join(root.path, 'Story.EPUB')).writeAsStringSync('not a real zip');
    File(p.join(root.path, 'notes.txt')).writeAsStringSync('no');
    final bookDir = Directory(p.join(root.path, 'Loose Book'))..createSync();
    File(p.join(bookDir.path, 'mimetype')).writeAsStringSync('application/epub+zip');
    final nested = Directory(p.join(root.path, 'other'))..createSync();
    File(p.join(nested.path, 'hidden.epub')).writeAsStringSync('skip');

    final scan = scanDirectories([root.path]);
    expect(scan.books.map((book) => book.fallbackTitle).toSet(), {'Story', 'Loose Book'});
    expect(scan.books.singleWhere((book) => book.fallbackTitle == 'Story').zipped, isTrue);
    expect(scan.books.singleWhere((book) => book.fallbackTitle == 'Loose Book').zipped, isFalse);
  });

  test('a file opened from another app is scanned once, and a missing one is left out', () {
    final root = Directory.systemTemp.createTempSync('epub-opened');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File(p.join(root.path, 'Opened Book.epub'))..writeAsStringSync('zip');
    final opened = scanFiles([file.path, file.path, p.join(root.path, 'gone.epub')]);
    expect(opened.map((book) => book.fallbackTitle), ['Opened Book']);
    expect(opened.single.zipped, isTrue);
    expect(scanFiles([file.path], skip: {canonicalPath(file.path)}), isEmpty);
  });

  test('shelf search matches the title or the file name, ignoring case and spaces', () {
    final book = ShelfBook(path: '/a.epub', zipped: true, fallbackTitle: 'half-real draft')..bookTitle = '電玩的本質';
    final other = ShelfBook(path: '/b.epub', zipped: true, fallbackTitle: 'Other');
    expect(filterBooks([book, other], '玩的'), [book]);
    expect(filterBooks([book, other], 'HALF - real'), [book]);
    expect(filterBooks([book, other], '  '), [book, other]);
    expect(filterBooks([book, other], 'zzz'), isEmpty);
  });

  test('shelf filters split books by reading state, and only archived and all show archived books', () {
    final fresh = ShelfBook(path: '/a', zipped: true, fallbackTitle: '甲');
    final reading = ShelfBook(path: '/b', zipped: true, fallbackTitle: '乙')
      ..lastRead = DateTime(2026)
      ..readProgress = 0.4;
    final done = ShelfBook(path: '/c', zipped: true, fallbackTitle: '丙')
      ..lastRead = DateTime(2026)
      ..readProgress = 1;
    final stored = ShelfBook(path: '/d', zipped: true, fallbackTitle: '丁')..archived = true;
    final gone = ShelfBook(path: '/e', zipped: true, fallbackTitle: '戊')..hidden = true;
    final all = [fresh, reading, done, stored, gone];
    List<String> pick(ShelfFilter filter) => [
          for (final book in all)
            if (bookPassesFilter(book, filter)) book.fallbackTitle,
        ];
    expect(pick(ShelfFilter.shelf), ['甲', '乙', '丙']);
    expect(pick(ShelfFilter.reading), ['乙']);
    expect(pick(ShelfFilter.unstarted), ['甲']);
    expect(pick(ShelfFilter.finished), ['丙']);
    expect(pick(ShelfFilter.archived), ['丁']);
    expect(pick(ShelfFilter.all), ['甲', '乙', '丙', '丁']);
    expect(
      emptyShelfNotice(directories: 1, books: 2, visible: 0, missing: 0, unreadable: 0, filter: ShelfFilter.finished)?.key,
      'shelf.empty_filter_none',
    );
  });

  test('the first end chapter in the last tenth marks the book finished', () {
    final labels = [
      '版權頁',
      for (var n = 1; n <= 16; n++) '第$n章',
      '譯者後記',
      '致謝',
      '註釋',
    ];
    expect(endChapter(labels), 18);
    expect(endChapter([...labels, '索引']), 18);
    expect(endChapter([...labels.take(17), '後記', '譯者', '致謝']), 18);
    expect(endChapter(['版權', '一', '二', '三']), isNull);
    expect(endChapter(['一', '二', '致谢']), 2);
    expect(endChapter(const []), isNull);

    final book = ShelfBook(path: '/a', zipped: true, fallbackTitle: '甲')
      ..lastRead = DateTime(2026)
      ..chapterIndex = 16
      ..readProgress = 0.85
      ..endChapter = 17;
    expect(bookStatus(book), BookStatus.reading);
    book.chapterIndex = 17;
    expect(bookStatus(book), BookStatus.finished);
    expect(bookPassesFilter(book, ShelfFilter.finished), isTrue);
    book.archived = true;
    expect(bookStatus(book), BookStatus.archived);
    expect(bookStatus(ShelfBook(path: '/b', zipped: true, fallbackTitle: '乙')), BookStatus.unstarted);
  });

  test('opened books without a folder are not called a missing folder', () {
    expect(
      emptyShelfNotice(directories: 0, books: 1, visible: 0, missing: 0, unreadable: 0)?.key,
      'shelf.empty_filtered',
    );
  });

  test('demo books are found when present, one per epub or unzipped folder', () {
    final demo = Directory('demo');
    if (!demo.existsSync()) return;
    final scan = scanDirectories([demo.path]);
    expect(
      scan.books.map((book) => p.basename(book.path)).toSet(),
      containsAll(['我，刀槍不入.epub', '電玩的本質']),
    );
  });
}
