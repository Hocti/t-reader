import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';

import 'i18n.dart';

/// One row of `assets/dict/word.csv`.
class DictEntry {
  const DictEntry({required this.word, required this.chinese, this.level = ''});

  final String word;

  /// Traditional Chinese, with part-of-speech marks such as `n.` and `vt.` inline.
  final String chinese;

  /// CEFR or AWL level. Often empty.
  final String level;

  /// [chinese] split before each part-of-speech mark.
  List<String> get senses => splitChineseSenses(chinese);
}

final _posMark = RegExp(r'(?<![A-Za-z])(?=(?:n|v|vi|vt|adj|adv|prep|conj|pron|num|int|interj|aux|art|abbr)\.)');

List<String> splitChineseSenses(String chinese) {
  return [
    for (final part in chinese.split(_posMark))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

/// The bundled English to Traditional Chinese word list.
class WordDictionary {
  WordDictionary._(this._words, this._forms);

  final Map<String, DictEntry> _words;

  /// Inflected form to headword, from the `lemmas` column. The more frequent headword wins.
  final Map<String, String> _forms;

  static Future<WordDictionary>? _loading;

  static Future<WordDictionary> load() {
    return _loading ??= () async {
      final raw = await rootBundle.loadString('assets/dict/word.csv');
      return Isolate.run(() => WordDictionary.parse(raw));
    }();
  }

  /// Rows are expected in frequency order, most frequent first.
  factory WordDictionary.parse(String raw) {
    final rows = parseCsv(raw);
    final words = <String, DictEntry>{};
    final forms = <String, String>{};
    if (rows.isEmpty) return WordDictionary._(words, forms);
    final header = rows.first;
    final wordAt = header.indexOf('word');
    final chineseAt = header.indexOf('tc');
    final lemmasAt = header.indexOf('lemmas');
    final levelAt = header.indexOf('cefr');
    if (wordAt < 0 || chineseAt < 0) return WordDictionary._(words, forms);
    String cell(List<String> row, int at) => at >= 0 && at < row.length ? row[at] : '';
    for (final row in rows.skip(1)) {
      final word = cell(row, wordAt).trim().toLowerCase();
      if (word.isEmpty || words.containsKey(word)) continue;
      words[word] = DictEntry(
        word: word,
        chinese: cell(row, chineseAt).trim(),
        level: cell(row, levelAt).trim(),
      );
      final lemmas = cell(row, lemmasAt);
      if (lemmas.isEmpty) continue;
      try {
        final list = jsonDecode(lemmas);
        if (list is! List) continue;
        for (final form in list) {
          if (form is! String) continue;
          final key = form.trim().toLowerCase();
          if (key.isNotEmpty) forms.putIfAbsent(key, () => word);
        }
      } catch (_) {}
    }
    return WordDictionary._(words, forms);
  }

  int get length => _words.length;

  /// Exact word, then a listed inflection, then common English endings.
  DictEntry? find(String raw) {
    final word = normalizeLookupWord(raw);
    if (word.isEmpty) return null;
    for (final candidate in lookupCandidates(word)) {
      final direct = _words[candidate];
      if (direct != null) return direct;
      final head = _forms[candidate];
      if (head != null && _words[head] != null) return _words[head];
    }
    return null;
  }
}

/// Lower case, straight apostrophes, no possessive `'s`, no edge punctuation.
String normalizeLookupWord(String raw) {
  var word = raw.trim().toLowerCase().replaceAll('\u2019', "'").replaceAll('\u2018', "'");
  word = word.replaceAll(RegExp(r"^[^a-z]+|[^a-z]+$"), '');
  if (word.endsWith("'s")) word = word.substring(0, word.length - 2);
  return word;
}

/// [word] first, then guesses at the base form of a regular inflection.
List<String> lookupCandidates(String word) {
  final out = <String>[word];
  void add(String value) {
    if (value.length >= 2 && !out.contains(value)) out.add(value);
  }

  bool doubled(String stem) => stem.length >= 3 && stem[stem.length - 1] == stem[stem.length - 2];

  if (word.endsWith('ies') && word.length > 4) add('${word.substring(0, word.length - 3)}y');
  if (word.endsWith('es') && word.length > 3) add(word.substring(0, word.length - 2));
  if (word.endsWith('s') && !word.endsWith('ss') && word.length > 3) add(word.substring(0, word.length - 1));
  if (word.endsWith('ied') && word.length > 4) add('${word.substring(0, word.length - 3)}y');
  if (word.endsWith('ed') && word.length > 4) {
    final stem = word.substring(0, word.length - 2);
    if (doubled(stem)) add(stem.substring(0, stem.length - 1));
    add(stem);
    add('${stem}e');
  }
  if (word.endsWith('ing') && word.length > 5) {
    final stem = word.substring(0, word.length - 3);
    if (doubled(stem)) add(stem.substring(0, stem.length - 1));
    add(stem);
    add('${stem}e');
  }
  if (word.endsWith('ly') && word.length > 4) add(word.substring(0, word.length - 2));
  if (word.contains('-')) add(word.replaceAll('-', ''));
  return out;
}

class WordSense {
  const WordSense({required this.definition, this.example});

  final String definition;
  final String? example;
}

/// Senses under one part of speech.
class WordMeaning {
  const WordMeaning({required this.partOfSpeech, required this.senses});

  final String partOfSpeech;
  final List<WordSense> senses;
}

class WikiSummary {
  const WikiSummary({required this.title, required this.extract, required this.language});

  final String title;
  final String extract;

  /// `zh` or `en`.
  final String language;
}

/// What the network found. `null` fields were not found or not asked for.
class OnlineLookup {
  const OnlineLookup({this.meanings = const [], this.chineseWiki, this.englishWiki, this.failed = false});

  final List<WordMeaning> meanings;
  final WikiSummary? chineseWiki;
  final WikiSummary? englishWiki;

  /// True when no request got an answer, so the phone is probably offline.
  final bool failed;
}

const _userAgent = 'EpubReader/0.1 (Android; offline-first reader)';
const _timeout = Duration(seconds: 12);

class _Answer {
  const _Answer(this.status, this.body);

  final int status;
  final Object? body;
}

Future<_Answer?> _getJson(Uri uri, {String? language}) async {
  final client = HttpClient()..connectionTimeout = _timeout;
  try {
    final request = await client.getUrl(uri).timeout(_timeout);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (language != null) request.headers.set(HttpHeaders.acceptLanguageHeader, language);
    final response = await request.close().timeout(_timeout);
    final text = await response.transform(utf8.decoder).join().timeout(_timeout);
    if (response.statusCode != 200) return _Answer(response.statusCode, null);
    return _Answer(200, jsonDecode(text));
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

final _cache = <String, Future<OnlineLookup>>{};

/// English senses from Wiktionary. Wikipedia summaries only when [needWiki] is true,
/// or when Wiktionary has nothing. The Chinese article is found through the English
/// article's language link and asked for in Hong Kong Traditional Chinese.
Future<OnlineLookup> lookupOnline(String word, {required bool needWiki}) {
  final key = '$word|$needWiki';
  return _cache[key] ??= _lookupOnline(word, needWiki).then((value) {
    if (value.failed) _cache.remove(key);
    return value;
  });
}

Future<OnlineLookup> _lookupOnline(String word, bool needWiki) async {
  final tries = <String>{word, word.toLowerCase()};
  List<WordMeaning> meanings = const [];
  var answered = false;
  for (final title in tries) {
    final answer = await _getJson(_restPage('en.wiktionary.org', 'definition', title));
    if (answer == null) continue;
    answered = true;
    meanings = parseWiktionary(answer.body);
    if (meanings.isNotEmpty) break;
  }
  if (!needWiki && meanings.isNotEmpty) return OnlineLookup(meanings: meanings);

  final links = await _getJson(
    Uri.https('en.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'prop': 'langlinks|pageprops',
      'lllang': 'zh',
      'redirects': '1',
      'titles': word,
    }),
  );
  if (links != null) answered = true;
  final page = _firstPage(links?.body);
  if (page == null || page.disambiguation) {
    return OnlineLookup(meanings: meanings, failed: !answered);
  }
  final results = await Future.wait([
    if (page.chineseTitle != null) _summary('zh', page.chineseTitle!) else Future.value(null),
    _summary('en', page.title),
  ]);
  return OnlineLookup(meanings: meanings, chineseWiki: results[0], englishWiki: results[1]);
}

/// `Uri.https` would encode the title a second time, and a `/` in it must stay escaped.
Uri _restPage(String host, String kind, String title) {
  return Uri.parse('https://$host/api/rest_v1/page/$kind/${Uri.encodeComponent(title.replaceAll(' ', '_'))}');
}

class _WikiPage {
  const _WikiPage(this.title, this.chineseTitle, this.disambiguation);

  final String title;
  final String? chineseTitle;
  final bool disambiguation;
}

_WikiPage? _firstPage(Object? body) {
  if (body is! Map) return null;
  final query = body['query'];
  if (query is! Map) return null;
  final pages = query['pages'];
  if (pages is! Map) return null;
  for (final page in pages.values) {
    if (page is! Map || page.containsKey('missing')) continue;
    final title = page['title'];
    if (title is! String) continue;
    String? chinese;
    final links = page['langlinks'];
    if (links is List && links.isNotEmpty && links.first is Map) {
      final value = (links.first as Map)['*'];
      if (value is String && value.isNotEmpty) chinese = value;
    }
    final props = page['pageprops'];
    final disambiguation = props is Map && props.containsKey('disambiguation');
    return _WikiPage(title, chinese, disambiguation);
  }
  return null;
}

Future<WikiSummary?> _summary(String language, String title) async {
  final answer = await _getJson(
    _restPage('$language.wikipedia.org', 'summary', title),
    language: language == 'zh' ? 'zh-hk' : null,
  );
  final body = answer?.body;
  if (body is! Map || body['type'] == 'disambiguation') return null;
  final extract = body['extract'];
  if (extract is! String || extract.trim().isEmpty) return null;
  // The display title follows the requested variant; the canonical one may be Simplified.
  final shown = body['displaytitle'];
  final display = shown is String ? plainFromHtml(shown) : '';
  return WikiSummary(title: display.isEmpty ? title : display, extract: extract.trim(), language: language);
}

/// The English entries of a Wiktionary `page/definition` answer, as plain text.
List<WordMeaning> parseWiktionary(Object? body) {
  if (body is! Map) return const [];
  final english = body['en'];
  if (english is! List) return const [];
  final out = <WordMeaning>[];
  for (final group in english) {
    if (group is! Map) continue;
    final pos = group['partOfSpeech'];
    final definitions = group['definitions'];
    if (definitions is! List) continue;
    final senses = <WordSense>[];
    for (final item in definitions) {
      if (item is! Map) continue;
      final text = plainFromHtml(item['definition'] as String? ?? '');
      if (text.isEmpty) continue;
      String? example;
      final examples = item['examples'];
      if (examples is List && examples.isNotEmpty && examples.first is String) {
        final value = plainFromHtml(examples.first as String);
        if (value.isNotEmpty) example = value;
      }
      senses.add(WordSense(definition: text, example: example));
      if (senses.length >= 8) break;
    }
    if (senses.isEmpty) continue;
    out.add(WordMeaning(partOfSpeech: pos is String ? pos : '', senses: senses));
  }
  return out;
}

final _tag = RegExp(r'<[^>]*>');
final _entity = RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);');
const _named = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'ndash': '–', 'mdash': '—'};

String plainFromHtml(String html) {
  final text = html.replaceAll(_tag, '').replaceAllMapped(_entity, (match) {
    final name = match.group(1)!;
    if (name.startsWith('#')) {
      final hex = name.startsWith('#x') || name.startsWith('#X');
      final code = int.tryParse(name.substring(hex ? 2 : 1), radix: hex ? 16 : 10);
      return code == null ? match.group(0)! : String.fromCharCode(code);
    }
    return _named[name] ?? match.group(0)!;
  });
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Headphones, earbuds, or a Bluetooth audio device are the current output.
Future<bool> headphonesConnected() async {
  if (!Platform.isAndroid) return false;
  try {
    return await const MethodChannel('epub_reader/audio').invokeMethod<bool>('headphones') ?? false;
  } catch (_) {
    return false;
  }
}
