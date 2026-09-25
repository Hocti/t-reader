import 'dart:io';

import 'package:epub_reader/src/page_paint.dart';
import 'package:epub_reader/src/reader_bridge.dart';
import 'package:epub_reader/src/reader_store.dart';
import 'package:epub_reader/src/sentences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  test('dressed chapter stays well-formed xhtml', () {
    final cover = File('demo/電玩的本質/OEBPS/cover.xhtml');
    final source = cover.existsSync()
        ? cover.readAsStringSync()
        : '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title>'
            '<meta name="viewport" content="width=1400, height=1986"/>'
            '</head><body><p>A &amp; B</p></body></html>';
    final prepared = prepareChapter(source);
    final dressed = dressChapter(
      prepared.html,
      paint: const PagePaint(page: '#ffffff', ink: '#000000'),
      layout: const ReaderLayout(),
    );
    final ready = dressed.replaceFirst(RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false), '');
    expect(dressed, contains('width=device-width'));
    expect(dressed, contains('<![CDATA['));
    expect(dressed, isNot(contains('width=1400')));
    XmlDocument.parse(ready);
  });
}
