import 'dart:convert';
import 'dart:io';

import 'package:epub_reader/src/book_files.dart';
import 'package:epub_reader/src/book_path.dart';
import 'package:epub_reader/src/nav_link.dart';
import 'package:epub_reader/src/parse_epub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('safe paths stay inside the book', () {
    expect(safeBookPath('OEBPS/../META-INF/container.xml'), 'META-INF/container.xml');
    expect(safeBookPath('../secret'), isNull);
    expect(
      resolveBookHref('OEBPS', 'ch01.xhtml#foot-1'),
      'OEBPS/ch01.xhtml',
    );
    expect(resolveBookHref('OEBPS', 'css/styles.css'), 'OEBPS/css/styles.css');
  });

  test('parses a tiny unzipped book', () async {
    final files = MemoryBookFiles({
      'META-INF/container.xml': _bytes('''
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''),
      'OEBPS/content.opf': _bytes('''
<package xmlns="http://www.idpf.org/2007/opf">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>  測試書  </dc:title>
  </metadata>
  <manifest>
    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="css" href="css/a.css" media-type="text/css"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>
'''),
      'OEBPS/nav.xhtml': _bytes('''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <body><nav epub:type="toc"><ol>
    <li><a href="c1.xhtml">第一章</a></li>
    <li><a href="c2.xhtml">第二章</a></li>
  </ol></nav></body>
</html>
'''),
    });

    final parsed = await parseBook(files);
    expect(parsed.ok, isTrue);
    expect(parsed.title, '測試書');
    expect(parsed.chapters.map((chapter) => chapter.path), [
      'OEBPS/c1.xhtml',
      'OEBPS/c2.xhtml',
    ]);
    expect(parsed.chapters.map((chapter) => chapter.label), ['第一章', '第二章']);
    expect(parsed.coverPath, isNull);
  });

  test('contents come nested from the nav document', () {
    final toc = readNav('''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
<nav epub:type="toc"><h1>書</h1><ol>
  <li><a href="x/c1.xhtml#a">第一章</a><ol>
    <li><a href="x/c2.xhtml">一之一</a></li>
  </ol></li>
  <li><span>附錄</span><ol><li><a href="x/c3.xhtml">附錄一</a></li></ol></li>
</ol></nav>
<nav epub:type="landmarks"><ol><li><a href="x/c9.xhtml">本文</a></li></ol></nav>
</body></html>
''', 'OEBPS');
    expect(toc.map((entry) => entry.label), ['第一章', '附錄']);
    expect(toc.first.path, 'OEBPS/x/c1.xhtml');
    expect(toc.first.fragment, 'a');
    expect(toc.first.children.single.label, '一之一');
    expect(toc.last.path, 'OEBPS/x/c3.xhtml');
  });

  test('a demo book lists only what its nav lists', () async {
    final demo = Directory('demo/勝出99%人的成癮式學習法');
    if (!demo.existsSync()) return;
    final parsed = await parseBook(DirectoryBookFiles(demo.path));
    expect(parsed.toc.length, 12);
    expect(parsed.toc.first.label, '書封');
    expect(parsed.toc[2].children.length, 3);
    final paths = <String>{};
    void visit(List<TocEntry> entries) {
      for (final entry in entries) {
        paths.add(entry.path);
        visit(entry.children);
      }
    }

    visit(parsed.toc);
    expect(paths, isNot(contains('item/xhtml/p-fmatter-001.xhtml')));
    expect(parsed.chapters.length, greaterThan(paths.length));
  });

  test('cover meta points at the manifest image', () async {
    final demo = Directory('demo/電玩的本質');
    if (!demo.existsSync()) return;
    final parsed = await parseBook(DirectoryBookFiles(demo.path));
    expect(parsed.coverPath, 'OEBPS/image/cover.jpg');
    final bytes = await DirectoryBookFiles(demo.path).read(parsed.coverPath!);
    expect(bytes, isNotNull);
    expect(bytes, isNotEmpty);
  });

  test('chapter links stay in the book and outside links are blocked', () {
    const chapters = ['OEBPS/c1.xhtml', 'OEBPS/c2.xhtml'];
    final next = decideBookNavigation(
      requestUrl: 'http://127.0.0.1:9/OEBPS/c2.xhtml#note',
      port: 9,
      chapterPaths: chapters,
    );
    expect(next.chapterIndex, 1);

    final same = decideBookNavigation(
      requestUrl: 'http://127.0.0.1:9/OEBPS/c1.xhtml#foot',
      port: 9,
      chapterPaths: chapters,
    );
    expect(same.chapterIndex, 0);
    expect(same.blocked, isFalse);

    final css = decideBookNavigation(
      requestUrl: 'http://127.0.0.1:9/OEBPS/css/a.css',
      port: 9,
      chapterPaths: chapters,
    );
    expect(css.chapterIndex, isNull);
    expect(css.blocked, isFalse);

    final outside = decideBookNavigation(
      requestUrl: 'https://example.com/book',
      port: 9,
      chapterPaths: chapters,
    );
    expect(outside.blocked, isTrue);
  });

  test('demo books expose an internal title and at least one chapter', () async {
    final folder = Directory('demo/電玩的本質');
    if (folder.existsSync()) {
      final parsed = await parseBook(DirectoryBookFiles(folder.path));
      expect(parsed.title, '電玩的本質');
      expect(parsed.chapters.length, 18);
      final first = await DirectoryBookFiles(folder.path).read(parsed.chapters.first.path);
      expect(first, isNotNull);
    }

    final zip = File('demo/我，刀槍不入.epub');
    if (zip.existsSync()) {
      final opened = await openZipBook(zip.path);
      final parsed = await parseBook(opened);
      expect(parsed.title, '我，刀槍不入');
      expect(parsed.chapters, isNotEmpty);
      final bytes = await opened.read(parsed.chapters.first.path);
      expect(bytes, isNotNull);
      expect(bytes, isNotEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

List<int> _bytes(String text) => utf8.encode(text);
