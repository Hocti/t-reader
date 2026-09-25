import 'package:xml/xml.dart';

enum SentenceType { title, content, list, quote, caption, note }

const speechBold = 1;
const speechItalic = 2;

/// Characters [start] to [end] of [Sentence.text] share one [style], a mix of [speechBold] and [speechItalic].
class SpeechRun {
  const SpeechRun(this.start, this.end, this.style);

  final int start;
  final int end;
  final int style;
}

class Sentence {
  const Sentence({
    required this.id,
    required this.type,
    required this.text,
    required this.segments,
    this.runs = const [],
  });

  final int id;
  final SentenceType type;
  final String text;
  final List<String> segments;

  /// Covers the whole text in order. Empty when nothing is bold or italic.
  final List<SpeechRun> runs;

  bool get speak => type != SentenceType.note && text.isNotEmpty;
}

class ChapterHeading {
  const ChapterHeading({
    required this.level,
    required this.text,
    required this.sentenceId,
  });

  final int level;
  final String text;
  final int sentenceId;
}

class PreparedChapter {
  const PreparedChapter({
    required this.html,
    required this.sentences,
    required this.headings,
  });

  final String html;
  final List<Sentence> sentences;
  final List<ChapterHeading> headings;
}

final _mooClass = RegExp(r'^(?:moofs\d+|moolh[0-9A-Za-z]+|non-moofont)$');
const _brMark = '\uE000';
const _listClasses = {'p22', 'p01', 'p02', 'p04', 'p05', 'p11'};
const _quoteClasses = {'kai', 'kc', 'kai-indent-5em', 'letter', 'quotes'};

PreparedChapter prepareChapter(String source) {
  try {
    final document = XmlDocument.parse(_xmlReady(source));
    final body = _firstLocal(document, 'body');
    if (body == null) {
      return PreparedChapter(html: source, sentences: const [], headings: const []);
    }
    final sentences = <Sentence>[];
    final headings = <ChapterHeading>[];
    _walk(body, sentences, headings);
    _wrapBody(body);
    return PreparedChapter(
      html: document.toXmlString(),
      sentences: sentences,
      headings: headings,
    );
  } catch (_) {
    return PreparedChapter(html: source, sentences: const [], headings: const []);
  }
}

void _walk(XmlElement el, List<Sentence> sentences, List<ChapterHeading> headings) {
  if (_skipWhole(el)) return;
  if (_isLeafBlock(el)) {
    final before = sentences.length;
    _fillBlock(el, sentences);
    final name = el.name.local.toLowerCase();
    if (sentences.length > before && (name == 'h3' || name == 'h4')) {
      final chunk = sentences.sublist(before);
      headings.add(
        ChapterHeading(
          level: name == 'h3' ? 3 : 4,
          text: chunk.map((sentence) => sentence.text).join(),
          sentenceId: chunk.first.id,
        ),
      );
    }
    return;
  }
  for (final child in el.childElements) {
    _walk(child, sentences, headings);
  }
}

void _fillBlock(XmlElement block, List<Sentence> sentences) {
  final align = _alignText(block);
  if (_isBlank(align)) return;
  final ranges = _sentenceRanges(align);
  if (ranges.isEmpty) return;
  final type = _typeOf(block);
  final styles = _alignStyles(block);
  final owner = List<int?>.filled(align.length, null);
  final cursor = _Cursor();
  for (final range in ranges) {
    final id = sentences.length;
    for (var i = range.start; i < range.end; i++) {
      owner[i] = id;
    }
    final raw = align.substring(range.start, range.end);
    final text = _normalize(raw);
    sentences.add(
      Sentence(
        id: id,
        type: type,
        text: text,
        segments: _segments(raw),
        runs: styles.length == align.length
            ? _speechRuns(raw, styles.sublist(range.start, range.end), text)
            : const [],
      ),
    );
  }
  cursor.owner = owner;
  final nodes = <XmlNode>[];
  for (final child in block.children) {
    nodes.addAll(_emit(child, cursor));
  }
  block.children.clear();
  block.children.addAll(nodes);
}

void _wrapBody(XmlElement body) {
  final kids = [for (final child in body.children) child.copy()];
  body.children.clear();
  final flow = XmlElement.tag(
    'div',
    attributes: [XmlAttribute(XmlName('id'), 'reader-flow')],
    children: kids,
    isSelfClosing: false,
  );
  final viewport = XmlElement.tag(
    'div',
    attributes: [XmlAttribute(XmlName('id'), 'reader-viewport')],
    children: [flow],
    isSelfClosing: false,
  );
  body.children.add(viewport);
}

class _Cursor {
  List<int?> owner = const [];
  var index = 0;
}

List<XmlNode> _emit(XmlNode node, _Cursor cursor) {
  if (node is XmlText) {
    final value = node.value;
    final out = <XmlNode>[];
    var i = 0;
    while (i < value.length) {
      final id = _ownerAt(cursor, cursor.index);
      final start = i;
      while (i < value.length && _ownerAt(cursor, cursor.index) == id) {
        i++;
        cursor.index++;
      }
      final slice = value.substring(start, i);
      if (slice.isEmpty) continue;
      if (id == null) {
        out.add(XmlText(slice));
      } else {
        out.add(_sentSpan(id, [XmlText(slice)]));
      }
    }
    return out;
  }
  if (node is! XmlElement) return const [];
  final name = node.name.local.toLowerCase();
  if (name == 'br') {
    cursor.index++;
    return [XmlElement.tag('br')];
  }
  if (_isNoteRef(node) || name == 'img' || name == 'svg') {
    return [node.copy()];
  }
  final copy = XmlElement(
    node.name.copy(),
    node.attributes.map((attribute) => attribute.copy()),
    const [],
    false,
  );
  for (final child in node.children) {
    copy.children.addAll(_emit(child, cursor));
  }
  return [copy];
}

int? _ownerAt(_Cursor cursor, int index) {
  if (index < 0 || index >= cursor.owner.length) return null;
  return cursor.owner[index];
}

XmlElement _sentSpan(int id, List<XmlNode> children) {
  return XmlElement.tag(
    'span',
    attributes: [
      XmlAttribute(XmlName('class'), 'sent'),
      XmlAttribute(XmlName('data-sid'), '$id'),
    ],
    children: children,
    isSelfClosing: false,
  );
}

String _alignText(XmlNode node) {
  final buffer = StringBuffer();
  void walk(XmlNode current) {
    if (current is XmlText) {
      buffer.write(current.value);
      return;
    }
    if (current is! XmlElement) return;
    final name = current.name.local.toLowerCase();
    if (name == 'br') {
      buffer.write(_brMark);
      return;
    }
    if (_isNoteRef(current) || name == 'img' || name == 'svg') return;
    for (final child in current.children) {
      walk(child);
    }
  }

  walk(node);
  return buffer.toString();
}

/// One bold/italic style per character of [_alignText].
List<int> _alignStyles(XmlNode node) {
  final styles = <int>[];
  void walk(XmlNode current, int style) {
    if (current is XmlText) {
      styles.addAll(List<int>.filled(current.value.length, style));
      return;
    }
    if (current is! XmlElement) return;
    final name = current.name.local.toLowerCase();
    if (name == 'br') {
      styles.add(style);
      return;
    }
    if (_isNoteRef(current) || name == 'img' || name == 'svg') return;
    final inner = style | _ownStyle(current);
    for (final child in current.children) {
      walk(child, inner);
    }
  }

  walk(node, 0);
  return styles;
}

final _boldCss = RegExp(r'font-weight\s*:\s*(?:bold|bolder|[6-9]00)', caseSensitive: false);
final _italicCss = RegExp(r'font-style\s*:\s*(?:italic|oblique)', caseSensitive: false);

/// Headings are bold by default in most books, so only inline tags, classes, and inline CSS count.
int _ownStyle(XmlElement el) {
  final name = el.name.local.toLowerCase();
  final classes = (el.getAttribute('class') ?? '').toLowerCase();
  final css = el.getAttribute('style') ?? '';
  var style = 0;
  if (name == 'b' || name == 'strong' || classes.contains('bold') || _boldCss.hasMatch(css)) {
    style |= speechBold;
  }
  if (name == 'i' || name == 'em' || classes.contains('italic') || _italicCss.hasMatch(css)) {
    style |= speechItalic;
  }
  return style;
}

/// Follows [_normalize] step by step so each style stays on its character.
List<SpeechRun> _speechRuns(String raw, List<int> styles, String text) {
  if (!styles.any((style) => style != 0)) return const [];
  final chars = <String>[];
  final marks = <int>[];
  const spaces = '\t\r\n\f ';
  var inSpace = false;
  for (var i = 0; i < raw.length; i++) {
    final char = raw[i];
    if (char == _brMark) continue;
    final isSpace = spaces.contains(char);
    if (isSpace && inSpace) continue;
    inSpace = isSpace;
    chars.add(isSpace ? ' ' : char);
    marks.add(styles[i]);
  }
  final keptChars = <String>[];
  final keptMarks = <int>[];
  for (var i = 0; i < chars.length; i++) {
    if (chars[i] == '\u3000') continue;
    keptChars.add(chars[i]);
    keptMarks.add(marks[i]);
  }
  final joined = keptChars.join();
  final lead = joined.length - joined.trimLeft().length;
  if (joined.trim() != text) return const [];
  final runs = <SpeechRun>[];
  for (var i = 0; i < text.length; i++) {
    final style = keptMarks[lead + i];
    if (runs.isNotEmpty && runs.last.style == style) {
      runs[runs.length - 1] = SpeechRun(runs.last.start, i + 1, style);
    } else {
      runs.add(SpeechRun(i, i + 1, style));
    }
  }
  return runs.length == 1 && runs.first.style == 0 ? const [] : runs;
}

List<({int start, int end})> _sentenceRanges(String align) {
  final ranges = <({int start, int end})>[];
  var start = 0;
  for (var i = 0; i < align.length; i++) {
    final char = align[i];
    if (char != '。' && char != '！' && char != '？') continue;
    final end = i + 1;
    if (!_isBlank(align.substring(start, end))) {
      ranges.add((start: start, end: end));
    }
    start = end;
  }
  if (start < align.length && !_isBlank(align.substring(start))) {
    ranges.add((start: start, end: align.length));
  }
  return ranges;
}

List<String> _segments(String raw) {
  final parts = <String>[];
  final buffer = StringBuffer();
  final stack = <String>[];
  const openers = {'「': '」', '『': '』', '《': '》', '（': '）', '(': ')'};
  for (final char in raw.split('')) {
    if (char == _brMark) {
      final piece = _normalize(buffer.toString());
      if (piece.isNotEmpty) parts.add(piece);
      buffer.clear();
      continue;
    }
    final closer = openers[char];
    if (closer != null) {
      stack.add(closer);
    } else if (stack.isNotEmpty && stack.last == char) {
      stack.removeLast();
    }
    buffer.write(char);
    if (stack.isEmpty && '，、；：'.contains(char)) {
      final piece = _normalize(buffer.toString());
      if (piece.isNotEmpty) parts.add(piece);
      buffer.clear();
    }
  }
  final tail = _normalize(buffer.toString());
  if (tail.isNotEmpty) parts.add(tail);
  if (parts.isEmpty) {
    final all = _normalize(raw);
    if (all.isNotEmpty) parts.add(all);
  }
  return parts;
}

String _normalize(String raw) {
  final withoutBreaks = raw.replaceAll(_brMark, '');
  return withoutBreaks.replaceAll(RegExp(r'[\t\r\n\f ]+'), ' ').replaceAll('\u3000', '').trim();
}

bool _isBlank(String raw) {
  return _normalize(raw).isEmpty;
}

bool _isLeafBlock(XmlElement el) {
  const blocks = {'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'blockquote', 'figcaption'};
  final name = el.name.local.toLowerCase();
  if (!blocks.contains(name)) return false;
  for (final child in el.descendants.whereType<XmlElement>()) {
    if (identical(child, el)) continue;
    final childName = child.name.local.toLowerCase();
    if (blocks.contains(childName) || childName == 'div') return false;
  }
  return true;
}

bool _skipWhole(XmlElement el) {
  final name = el.name.local.toLowerCase();
  if (name == 'hr' || name == 'img' || name == 'svg' || name == 'script' || name == 'style') {
    return true;
  }
  final classes = _semanticClasses(el);
  if (name == 'p' && (classes.contains('pic') || classes.contains('ct'))) return true;
  return false;
}

SentenceType _typeOf(XmlElement el) {
  final name = el.name.local.toLowerCase();
  final classes = _semanticClasses(el);
  final epub = _attrLocal(el, 'type');
  if (classes.contains('footnote') || classes.contains('footnote0') || epub == 'footnote') {
    return SentenceType.note;
  }
  if (RegExp(r'^h[1-6]$').hasMatch(name)) return SentenceType.title;
  if (classes.contains('leading') || classes.contains('leading1')) return SentenceType.title;
  if (classes.contains('caption') || classes.contains('caption-b') || classes.contains('caption01')) {
    return SentenceType.caption;
  }
  if (name == 'blockquote' || classes.any(_quoteClasses.contains)) return SentenceType.quote;
  if (classes.any(_listClasses.contains)) return SentenceType.list;
  return SentenceType.content;
}

bool _isNoteRef(XmlElement el) {
  if (el.name.local.toLowerCase() != 'a') return false;
  if (_semanticClasses(el).contains('ref')) return true;
  return _attrLocal(el, 'type') == 'noteref';
}

Set<String> _semanticClasses(XmlElement el) {
  final raw = el.getAttribute('class') ?? '';
  return raw.split(RegExp(r'\s+')).where((name) => name.isNotEmpty && !_mooClass.hasMatch(name)).toSet();
}

String _attrLocal(XmlElement el, String name) {
  for (final attribute in el.attributes) {
    if (attribute.name.local == name) return attribute.value;
  }
  return '';
}

XmlElement? _firstLocal(XmlNode node, String name) {
  for (final element in node.descendants.whereType<XmlElement>()) {
    if (element.name.local == name) return element;
  }
  return null;
}

String _xmlReady(String source) {
  var text = source;
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  text = text.replaceFirst(RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false), '');
  return text;
}
