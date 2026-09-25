import 'sentences.dart';

/// One image counts as this many characters when weighing a chapter.
const imageWeight = 300;

final _imageTag = RegExp(r'<(?:img|image)\b', caseSensitive: false);

final _imageElement = RegExp(r'<(img|image)\b([^>]*)>', caseSensitive: false);
final _imageLink = RegExp(r'''(?:^|\s)(src|xlink:href|href)\s*=\s*(?:"([^"]*)"|'([^']*)')''', caseSensitive: false);

/// The `src` of each `img` and the link of each SVG `image` in the chapter's text, in document order.
/// Null where an element has none, so the index still matches the n-th element on the page.
List<String?> imageSources(String html) {
  final at = html.indexOf('reader-flow');
  final body = at < 0 ? html : html.substring(at);
  return [
    for (final match in _imageElement.allMatches(body)) _imageHref(match.group(1)!.toLowerCase(), match.group(2) ?? ''),
  ];
}

String? _imageHref(String tag, String attributes) {
  for (final match in _imageLink.allMatches(attributes)) {
    final name = match.group(1)!.toLowerCase();
    if (tag == 'img' ? name != 'src' : name == 'src') continue;
    final value = (match.group(2) ?? match.group(3) ?? '').replaceAll('&amp;', '&').trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

/// Chapter names that mean the story is over: acknowledgements, copyright, notes, translator.
const endWords = ['致謝', '致谢', '版權', '版权', '註釋', '注釋', '注释', '譯者', '译者'];

/// The first chapter in the last tenth of [labels] whose name has one of [endWords].
/// Reaching it counts as finishing the book. Null when there is none.
int? endChapter(List<String> labels) {
  if (labels.isEmpty) return null;
  final from = (labels.length * 0.9).floor().clamp(0, labels.length - 1);
  for (var index = from; index < labels.length; index++) {
    if (endWords.any(labels[index].contains)) return index;
  }
  return null;
}

class ChapterText {
  const ChapterText({required this.texts, required this.notes, required this.images, this.imageSources = const []});

  /// Sentence text by sentence id.
  final List<String> texts;

  /// Sentence ids that are footnotes.
  final Set<int> notes;
  final int images;

  /// From [imageSources].
  final List<String?> imageSources;

  int get chars {
    var total = 0;
    for (var id = 0; id < texts.length; id++) {
      if (!notes.contains(id)) total += texts[id].length;
    }
    return total;
  }

  /// Characters and images, without footnotes.
  int get weight => chars + images * imageWeight;
}

ChapterText analyzeChapter(String source) {
  final prepared = prepareChapter(source);
  return ChapterText(
    texts: [for (final sentence in prepared.sentences) sentence.text],
    notes: {
      for (final sentence in prepared.sentences)
        if (sentence.type == SentenceType.note) sentence.id,
    },
    images: _imageTag.allMatches(source).length,
    imageSources: imageSources(prepared.html),
  );
}

List<ChapterText> analyzeBook(List<String> sources) => [for (final source in sources) analyzeChapter(source)];

/// How far into one chapter the page is, from 0 to 1.
/// Text before [firstSentence] decides it. Footnotes do not count.
/// A chapter with no text falls back to the page number.
double chapterFraction({
  required List<Sentence> sentences,
  required int? firstSentence,
  required int page,
  required int pageCount,
}) {
  var total = 0;
  var before = 0;
  for (final sentence in sentences) {
    if (sentence.type == SentenceType.note) continue;
    total += sentence.text.length;
    if (firstSentence != null && sentence.id < firstSentence) before += sentence.text.length;
  }
  if (total == 0 || firstSentence == null || firstSentence < 0) {
    if (pageCount <= 0) return 0;
    return (page / pageCount).clamp(0.0, 1.0);
  }
  return (before / total).clamp(0.0, 1.0);
}

/// Share of the book read. [weights] come from [ChapterText.weight].
/// Without weights, each chapter counts the same.
double bookProgress({
  required List<int>? weights,
  required int chapterCount,
  required int chapter,
  required double inChapter,
  bool atEnd = false,
}) {
  if (chapterCount <= 0) return 0;
  if (atEnd && chapter >= chapterCount - 1) return 1;
  final index = chapter.clamp(0, chapterCount - 1);
  if (weights != null && weights.length == chapterCount) {
    var total = 0;
    var before = 0;
    for (var i = 0; i < weights.length; i++) {
      total += weights[i];
      if (i < index) before += weights[i];
    }
    if (total > 0) return ((before + weights[index] * inChapter) / total).clamp(0.0, 1.0);
  }
  return ((index + inChapter) / chapterCount).clamp(0.0, 1.0);
}

/// The reverse of [bookProgress]: which chapter holds [progress], and how far into it.
({int chapter, double inChapter}) locateProgress({
  required List<int>? weights,
  required int chapterCount,
  required double progress,
}) {
  if (chapterCount <= 0) return (chapter: 0, inChapter: 0);
  final value = progress.clamp(0.0, 1.0);
  if (weights != null && weights.length == chapterCount) {
    final total = weights.fold<int>(0, (sum, weight) => sum + weight);
    if (total > 0) {
      final goal = value * total;
      var before = 0;
      for (var i = 0; i < chapterCount; i++) {
        final weight = weights[i];
        if (weight > 0 && (goal < before + weight || i == chapterCount - 1)) {
          return (chapter: i, inChapter: ((goal - before) / weight).clamp(0.0, 1.0));
        }
        before += weight;
      }
      return (chapter: chapterCount - 1, inChapter: 1);
    }
  }
  final spot = value * chapterCount;
  final chapter = spot.floor().clamp(0, chapterCount - 1);
  return (chapter: chapter, inChapter: (spot - chapter).clamp(0.0, 1.0));
}

/// Where each chapter starts, as a share of the book. Same weighting as [bookProgress].
List<double> chapterStarts({required List<int>? weights, required int chapterCount}) {
  return [
    for (var i = 0; i < chapterCount; i++)
      bookProgress(weights: weights, chapterCount: chapterCount, chapter: i, inChapter: 0),
  ];
}

/// The chapter whose start is within [reach] of [progress], nearest first. Null when none is.
int? snapChapter(List<double> starts, double progress, double reach) {
  int? best;
  var gap = reach;
  for (var i = 0; i < starts.length; i++) {
    final d = (starts[i] - progress).abs();
    if (d <= gap) {
      gap = d;
      best = i;
    }
  }
  return best;
}

/// The sentence where [fraction] of the chapter's text has been passed. The reverse of [chapterFraction].
int? sentenceAtFraction(List<Sentence> sentences, double fraction) {
  var total = 0;
  for (final sentence in sentences) {
    if (sentence.type != SentenceType.note) total += sentence.text.length;
  }
  if (total == 0) return null;
  final goal = fraction.clamp(0.0, 1.0) * total;
  var before = 0;
  int? last;
  for (final sentence in sentences) {
    if (sentence.type == SentenceType.note) continue;
    last = sentence.id;
    if (before + sentence.text.length > goal) return sentence.id;
    before += sentence.text.length;
  }
  return last;
}

class SearchHit {
  const SearchHit({required this.chapter, required this.sentenceId, required this.snippet});

  final int chapter;
  final int sentenceId;
  final String snippet;
}

/// Case-insensitive match inside each sentence. At most [limit] hits.
List<SearchHit> searchBook(List<ChapterText> chapters, String query, {int limit = 300}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  final hits = <SearchHit>[];
  for (var chapter = 0; chapter < chapters.length; chapter++) {
    final texts = chapters[chapter].texts;
    for (var id = 0; id < texts.length; id++) {
      final text = texts[id];
      final at = text.toLowerCase().indexOf(needle);
      if (at < 0) continue;
      hits.add(SearchHit(chapter: chapter, sentenceId: id, snippet: _snippet(text, at, needle.length)));
      if (hits.length >= limit) return hits;
    }
  }
  return hits;
}

String _snippet(String text, int at, int length) {
  const before = 16;
  const after = 40;
  final start = at - before < 0 ? 0 : at - before;
  final end = at + length + after > text.length ? text.length : at + length + after;
  return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
}
