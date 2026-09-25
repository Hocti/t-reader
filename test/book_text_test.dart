import 'package:epub_reader/src/book_text.dart';
import 'package:epub_reader/src/page_paint.dart';
import 'package:epub_reader/src/reader_bridge.dart';
import 'package:epub_reader/src/reader_store.dart';
import 'package:epub_reader/src/sentences.dart';
import 'package:flutter_test/flutter_test.dart';

const _chapter = '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
    '<head></head><body>'
    '<p>第一句。第二句很長很長。</p>'
    '<p><img src="a.png"/></p>'
    '<p class="footnote" epub:type="footnote">這是註釋，不計。</p>'
    '</body></html>';

void main() {
  test('chapter weight counts text and images, not notes', () {
    final text = analyzeChapter(_chapter);
    expect(text.texts.length, 3);
    expect(text.notes, {2});
    expect(text.chars, '第一句。'.length + '第二句很長很長。'.length);
    expect(text.images, 1);
    expect(text.weight, text.chars + imageWeight);
  });

  test('chapter fraction follows the text before the first sentence on the page', () {
    final sentences = prepareChapter(_chapter).sentences;
    expect(chapterFraction(sentences: sentences, firstSentence: 0, page: 0, pageCount: 2), 0);
    final half = chapterFraction(sentences: sentences, firstSentence: 1, page: 1, pageCount: 2);
    expect(half, closeTo(4 / 12, 1e-9));
    expect(chapterFraction(sentences: const [], firstSentence: null, page: 1, pageCount: 4), 0.25);
  });

  test('book progress weighs chapters and reaches 1 at the last page', () {
    expect(bookProgress(weights: [100, 300], chapterCount: 2, chapter: 1, inChapter: 0.5), closeTo(250 / 400, 1e-9));
    expect(bookProgress(weights: null, chapterCount: 4, chapter: 1, inChapter: 0.5), 0.375);
    expect(bookProgress(weights: [1, 1], chapterCount: 2, chapter: 1, inChapter: 0.9, atEnd: true), 1);
  });

  test('a dragged percent finds its chapter and sentence again', () {
    final spot = locateProgress(weights: [100, 300], chapterCount: 2, progress: 250 / 400);
    expect(spot.chapter, 1);
    expect(spot.inChapter, closeTo(0.5, 1e-9));
    expect(locateProgress(weights: [100, 300], chapterCount: 2, progress: 0.1).chapter, 0);
    expect(locateProgress(weights: [100, 300], chapterCount: 2, progress: 1).chapter, 1);
    expect(locateProgress(weights: null, chapterCount: 4, progress: 0.375).chapter, 1);

    final sentences = prepareChapter(_chapter).sentences;
    expect(sentenceAtFraction(sentences, 0), 0);
    expect(sentenceAtFraction(sentences, 4 / 12), 1);
    expect(sentenceAtFraction(sentences, 1), 1);
    expect(sentenceAtFraction(const [], 0.5), isNull);
  });

  test('search finds sentences in every chapter, ignoring case', () {
    final book = [
      analyzeChapter(_chapter),
      analyzeChapter('<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Hello World。</p></body></html>'),
    ];
    final hits = searchBook(book, '很長');
    expect(hits.single.chapter, 0);
    expect(hits.single.sentenceId, 1);
    expect(searchBook(book, 'world').single.chapter, 1);
    expect(searchBook(book, '  '), isEmpty);
  });

  test('highlight rules outrank the forced theme colors', () {
    final css = readerCss(
      const PagePaint(page: '#1a2330', ink: '#e6edf4', accent: '#d2a24c', onAccent: '#1a2330'),
      const ReaderLayout(),
    );
    expect(css, contains('#reader-flow, #reader-flow * {\n  color: #e6edf4 !important;'));
    expect(css, contains('#reader-flow .picked, #reader-flow .picked * {\n  background-color: #d2a24c !important;'));
    expect(css.indexOf('#reader-flow .reading'), greaterThan(css.indexOf('color: #e6edf4 !important')));
  });
}
