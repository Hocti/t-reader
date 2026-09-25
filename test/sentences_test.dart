import 'dart:io';

import 'package:epub_reader/src/page_paint.dart';
import 'package:epub_reader/src/pages/reader_page.dart';
import 'package:epub_reader/src/reader_bridge.dart';
import 'package:epub_reader/src/reader_store.dart';
import 'package:epub_reader/src/sentences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('marks bold and italic runs for speech', () {
    final prepared = prepareChapter('''
<html xmlns="http://www.w3.org/1999/xhtml">
<body>
  <p>　他說<b>不要</b>，然後讀了<i>Half  Real</i>。<span style="font-weight: 700"><em>好</em>書</span>！</p>
  <h2>標題</h2>
</body>
</html>
''');
    final first = prepared.sentences[0];
    expect(first.text, '他說不要，然後讀了Half Real。');
    String part(Sentence sentence, SpeechRun run) => sentence.text.substring(run.start, run.end);
    expect([for (final run in first.runs) (part(first, run), run.style)], [
      ('他說', 0),
      ('不要', speechBold),
      ('，然後讀了', 0),
      ('Half Real', speechItalic),
      ('。', 0),
    ]);
    final second = prepared.sentences[1];
    expect([for (final run in second.runs) (part(second, run), run.style)], [
      ('好', speechBold | speechItalic),
      ('書', speechBold),
      ('！', 0),
    ]);
    expect(prepared.sentences[2].runs, isEmpty);
  });

  test('italic speech picks another speaker in the same locale', () {
    const voices = [
      SystemVoice(name: 'yue-HK-language', locale: 'yue-HK'),
      SystemVoice(name: 'yue-hk-x-jar-local', locale: 'yue-HK'),
      SystemVoice(name: 'yue-hk-x-jar-network', locale: 'yue-HK'),
      SystemVoice(name: 'yue-hk-x-yuc-network', locale: 'yue-HK'),
      SystemVoice(name: 'yue-hk-x-yud-local', locale: 'yue-HK'),
      SystemVoice(name: 'cmn-tw-x-cte-local', locale: 'zh-TW'),
    ];
    expect(pickSecondVoice(voices, voices[1])?.name, 'yue-hk-x-yud-local');
    expect(pickSecondVoice(const [SystemVoice(name: 'a', locale: 'yue-HK')], const SystemVoice(name: 'a', locale: 'yue-HK')), isNull);
  });

  test('splits a Readmoo-shaped paragraph into sentences and segments', () {
    final prepared = prepareChapter('''
<html xmlns="http://www.w3.org/1999/xhtml">
<body>
  <p class="leading moofs20">[1]</p>
  <h2>入門<br/><span class="bracket">Introduction</span></h2>
  <p class="moofs16">　</p>
  <p class="moofs16">本書原文以「半真實」（Half-Real）為名，意指電玩遊戲同時具有兩種面向。在<span class="kais">真實</span>的面向上，電玩由真實規則組成。</p>
  <p>電玩的歷史不過四十年出頭，<a class="ref" epub:type="noteref" href="#foot-1">[1]</a>電玩進入流行文化不過才三十多年。</p>
  <p class="p22">一、一個以規則為基礎的形式系統。</p>
  <p class="kai">他說「你好，世界」，然後離開。</p>
  <p class="ct">※※※</p>
  <h4>又舊又新的電玩</h4>
  <p class="caption">圖1.1：箭頭。</p>
  <p class="footnote" epub:type="footnote"><span class="no">[1]</span>譯註：自原文出版起算。</p>
</body>
</html>
''');

    final title = prepared.sentences.firstWhere((sentence) => sentence.text.contains('入門'));
    expect(title.type, SentenceType.title);
    expect(title.segments, ['入門', 'Introduction']);

    final first = prepared.sentences.firstWhere((sentence) => sentence.text.startsWith('本書原文'));
    expect(first.type, SentenceType.content);
    expect(first.segments, [
      '本書原文以「半真實」（Half-Real）為名，',
      '意指電玩遊戲同時具有兩種面向。',
    ]);
    expect(prepared.sentences.where((sentence) => sentence.text == '真實'), isEmpty);

    final history = prepared.sentences.firstWhere((sentence) => sentence.text.contains('四十年'));
    expect(history.text, '電玩的歷史不過四十年出頭，電玩進入流行文化不過才三十多年。');
    expect(history.text.contains('[1]'), isFalse);

    expect(
      prepared.sentences.firstWhere((sentence) => sentence.text.startsWith('一、')).type,
      SentenceType.list,
    );
    final quote = prepared.sentences.firstWhere((sentence) => sentence.text.startsWith('他說'));
    expect(quote.type, SentenceType.quote);
    expect(quote.segments, ['他說「你好，世界」，', '然後離開。']);

    expect(prepared.sentences.any((sentence) => sentence.text.contains('※')), isFalse);
    expect(
      prepared.sentences.firstWhere((sentence) => sentence.text.startsWith('圖1.1')).type,
      SentenceType.caption,
    );
    final note = prepared.sentences.firstWhere((sentence) => sentence.type == SentenceType.note);
    expect(note.speak, isFalse);
    expect(note.text, contains('譯註'));

    final heading = prepared.headings.single;
    expect(heading.level, 4);
    expect(heading.text, '又舊又新的電玩');
    expect(prepared.html, contains('data-sid="${first.id}"'));
    expect(prepared.html, contains('class="kais"'));
  });

  test('sample Readmoo chapter matches the sentence rules', () {
    final file = File('demo/電玩的本質/OEBPS/ch01.xhtml');
    expect(file.existsSync(), isTrue, reason: 'demo chapter is on this machine');
    final prepared = prepareChapter(file.readAsStringSync());
    final first = prepared.sentences.firstWhere((sentence) => sentence.type == SentenceType.content);
    expect(first.text, startsWith('本書原文以「半真實」（Half-Real）為名，意指電玩遊戲同時具有兩種面向。'));
    expect(first.segments.first, '本書原文以「半真實」（Half-Real）為名，');
    final title = prepared.sentences.firstWhere((sentence) => sentence.segments.contains('Introduction'));
    expect(title.type, SentenceType.title);
    expect(title.segments, ['入門', 'Introduction']);
    expect(prepared.sentences.where((sentence) => sentence.type == SentenceType.note), isNotEmpty);
    expect(
      prepared.sentences.any((sentence) => sentence.type == SentenceType.content && sentence.text.contains('[1]')),
      isFalse,
    );
    expect(prepared.headings.any((heading) => heading.text == '什麼是遊戲？'), isTrue);
  });

  test('dressed chapter keeps sentence marks and page settings', () {
    final prepared = prepareChapter('<html xmlns="http://www.w3.org/1999/xhtml"><head></head><body><p>你好，世界。</p></body></html>');
    expect(prepared.html, contains('<div id="reader-viewport">'));
    final dressed = dressChapter(
      prepared.html,
      paint: const PagePaint(page: '#ffffff', ink: '#000000'),
      layout: const ReaderLayout(margin: MarginStep.wide, writing: WritingMode.vertical, turn: TurnMode.scroll),
    );
    expect(dressed, contains('data-mode="scroll"'));
    expect(dressed, contains('data-writing="vertical"'));
    expect(dressed, contains('data-margin="40"'));
    expect(dressed, contains('data-sid="0"'));
    expect(dressed, contains('epub-reader-script'));
  });

  test('only a move of more than one page is a jump', () {
    expect(
      isSinglePageStep(
        fromChapter: 1,
        fromPage: 2,
        fromPageCount: 10,
        toChapter: 1,
        toPage: 3,
        toPageCount: 10,
      ),
      isTrue,
    );
    expect(
      isSinglePageStep(
        fromChapter: 1,
        fromPage: 2,
        fromPageCount: 10,
        toChapter: 1,
        toPage: 5,
        toPageCount: 10,
      ),
      isFalse,
    );
    expect(
      isSinglePageStep(
        fromChapter: 1,
        fromPage: 9,
        fromPageCount: 10,
        toChapter: 2,
        toPage: 0,
        toPageCount: 4,
      ),
      isTrue,
    );
    expect(
      isSinglePageStep(
        fromChapter: 2,
        fromPage: 0,
        fromPageCount: 4,
        toChapter: 1,
        toPage: 9,
        toPageCount: 10,
      ),
      isTrue,
    );
  });
}
