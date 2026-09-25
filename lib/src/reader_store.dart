import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MarginStep { narrow, normal, wide }

enum WritingMode { horizontal, vertical }

enum FontFace { sans, serif }

enum FontStep { small, smaller, normal, larger, large }

enum LineStep { tight, normal, loose }

enum TurnMode { page, scroll }

/// Two columns apply only to horizontal pages on a screen wider than [twoColumnMinWidth].
enum ColumnMode { single, double }

const twoColumnMinWidth = 800.0;

enum SpeechPace { slow, slower, normal, faster, fast }

enum SpeechEngine { system, cloud }

enum SpeechLanguage { cantonese, mandarin, english }

class SystemVoice {
  const SystemVoice({required this.name, required this.locale});

  final String name;
  final String locale;
}

/// Locale passed to the system voice when no installed voice matches.
String preferredSpeechLocale(SpeechLanguage language) => switch (language) {
      SpeechLanguage.cantonese => 'zh-HK',
      SpeechLanguage.mandarin => 'zh-TW',
      SpeechLanguage.english => 'en-US',
    };

String _normLocale(String locale) => locale.toLowerCase().replaceAll('_', '-');

bool voiceMatchesLanguage(String locale, SpeechLanguage language) {
  final n = _normLocale(locale);
  return switch (language) {
    SpeechLanguage.cantonese => n.startsWith('yue') || n.startsWith('zh-hk') || n.contains('-yue'),
    SpeechLanguage.mandarin =>
      n.startsWith('zh-tw') ||
          n.startsWith('zh-cn') ||
          n.startsWith('cmn') ||
          n == 'zh' ||
          (n.startsWith('zh-') && !n.startsWith('zh-hk') && !n.contains('-yue')),
    SpeechLanguage.english => n.startsWith('en'),
  };
}

/// Lower is a better match. Voices that do not match stay out of [pickSystemVoice].
int _voiceRank(String locale, SpeechLanguage language) {
  final n = _normLocale(locale);
  return switch (language) {
    SpeechLanguage.cantonese => n.startsWith('yue') ? 0 : 1,
    SpeechLanguage.mandarin => n.startsWith('zh-tw')
        ? 0
        : n.startsWith('cmn-tw')
            ? 1
            : n.startsWith('zh-cn') || n.startsWith('cmn-cn')
                ? 2
                : 3,
    SpeechLanguage.english => n.startsWith('en-us')
        ? 0
        : n.startsWith('en-gb')
            ? 1
            : 2,
  };
}

SystemVoice? pickSystemVoice(Iterable<SystemVoice> voices, SpeechLanguage language) {
  final matches = [
    for (final voice in voices)
      if (voice.name.isNotEmpty && voice.locale.isNotEmpty && voiceMatchesLanguage(voice.locale, language)) voice,
  ];
  if (matches.isEmpty) return null;
  matches.sort((a, b) {
    final rank = _voiceRank(a.locale, language).compareTo(_voiceRank(b.locale, language));
    if (rank != 0) return rank;
    final locale = a.locale.compareTo(b.locale);
    if (locale != 0) return locale;
    return a.name.compareTo(b.name);
  });
  return matches.first;
}

/// The speaker code in names such as `yue-hk-x-jar-local`, or the whole name.
String _speakerOf(String name) {
  final match = RegExp(r'-x-([a-z0-9]+)', caseSensitive: false).firstMatch(name);
  return (match?.group(1) ?? name).toLowerCase();
}

/// Another speaker in the same locale as [main], for italic text. Offline voices first.
SystemVoice? pickSecondVoice(Iterable<SystemVoice> voices, SystemVoice? main) {
  if (main == null) return null;
  final locale = _normLocale(main.locale);
  final speaker = _speakerOf(main.name);
  final matches = [
    for (final voice in voices)
      if (voice.name.isNotEmpty &&
          _normLocale(voice.locale) == locale &&
          voice.name != main.name &&
          _speakerOf(voice.name) != speaker)
        voice,
  ];
  if (matches.isEmpty) return null;
  // Google's `…-language` entry is the default speaker under another name.
  int alias(SystemVoice voice) => voice.name.toLowerCase().endsWith('-language') ? 1 : 0;
  int online(SystemVoice voice) => voice.name.contains('network') ? 1 : 0;
  matches.sort((a, b) {
    final same = alias(a).compareTo(alias(b));
    if (same != 0) return same;
    final network = online(a).compareTo(online(b));
    if (network != 0) return network;
    return a.name.compareTo(b.name);
  });
  return matches.first;
}

/// An installed `en-GB` voice for lookups, if there is one.
SystemVoice? pickBritishVoice(Iterable<SystemVoice> voices) {
  final matches = [
    for (final voice in voices)
      if (voice.name.isNotEmpty && _normLocale(voice.locale).startsWith('en-gb')) voice,
  ];
  if (matches.isEmpty) return null;
  // Offline voices first, so a lookup speaks at once without the network.
  int online(SystemVoice voice) => voice.name.contains('network') ? 1 : 0;
  matches.sort((a, b) {
    final network = online(a).compareTo(online(b));
    if (network != 0) return network;
    return a.name.compareTo(b.name);
  });
  return matches.first;
}

SpeechLanguage? languageFromLocale(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  for (final language in SpeechLanguage.values) {
    if (voiceMatchesLanguage(raw, language)) return language;
  }
  return null;
}

class ReaderLayout {
  const ReaderLayout({
    this.margin = MarginStep.normal,
    this.marginV = MarginStep.normal,
    this.writing = WritingMode.horizontal,
    this.font = FontFace.sans,
    this.fontStep = FontStep.normal,
    this.line = LineStep.normal,
    this.turn = TurnMode.page,
    this.columns = ColumnMode.single,
  });

  /// Left and right.
  final MarginStep margin;

  /// Top and bottom.
  final MarginStep marginV;
  final WritingMode writing;
  final FontFace font;
  final FontStep fontStep;
  final LineStep line;
  final TurnMode turn;
  final ColumnMode columns;

  int get marginPx => switch (margin) {
        MarginStep.narrow => 12,
        MarginStep.normal => 24,
        MarginStep.wide => 40,
      };

  /// Added to the fixed bands above and below the text. The top band holds the temporary bookmark.
  int get marginVPx => switch (marginV) {
        MarginStep.narrow => 0,
        MarginStep.normal => 12,
        MarginStep.wide => 32,
      };

  int get fontPx => switch (fontStep) {
        FontStep.small => 16,
        FontStep.smaller => 18,
        FontStep.normal => 20,
        FontStep.larger => 24,
        FontStep.large => 28,
      };

  double get lineHeight => switch (line) {
        LineStep.tight => 1.45,
        LineStep.normal => 1.7,
        LineStep.loose => 2.05,
      };

  String get fontFamily => font == FontFace.serif ? 'serif' : 'sans-serif';

  ReaderLayout copyWith({
    MarginStep? margin,
    MarginStep? marginV,
    WritingMode? writing,
    FontFace? font,
    FontStep? fontStep,
    LineStep? line,
    TurnMode? turn,
    ColumnMode? columns,
  }) {
    return ReaderLayout(
      margin: margin ?? this.margin,
      marginV: marginV ?? this.marginV,
      writing: writing ?? this.writing,
      font: font ?? this.font,
      fontStep: fontStep ?? this.fontStep,
      line: line ?? this.line,
      turn: turn ?? this.turn,
      columns: columns ?? this.columns,
    );
  }

  Map<String, String> toJson() => {
        'margin': margin.name,
        'marginV': marginV.name,
        'writing': writing.name,
        'font': font.name,
        'fontStep': fontStep.name,
        'line': line.name,
        'turn': turn.name,
        'columns': columns.name,
      };

  static ReaderLayout fromJson(Object? raw) {
    if (raw is! Map) return const ReaderLayout();
    return ReaderLayout(
      margin: _enum(MarginStep.values, raw['margin'], MarginStep.normal),
      marginV: _enum(MarginStep.values, raw['marginV'], MarginStep.normal),
      writing: _enum(WritingMode.values, raw['writing'], WritingMode.horizontal),
      font: _enum(FontFace.values, raw['font'], FontFace.sans),
      fontStep: _enum(FontStep.values, raw['fontStep'], FontStep.normal),
      line: _enum(LineStep.values, raw['line'], LineStep.normal),
      turn: _enum(TurnMode.values, raw['turn'], TurnMode.page),
      columns: _enum(ColumnMode.values, raw['columns'], ColumnMode.single),
    );
  }
}

/// [start] and [end] are sentence ids. The offsets count characters into those sentences.
/// A null [endOffset] runs to the end of the last sentence, as in highlights saved before offsets.
class HighlightMark {
  const HighlightMark({
    required this.chapter,
    required this.start,
    required this.end,
    required this.text,
    this.startOffset = 0,
    this.endOffset,
    this.created,
  });

  final int chapter;
  final int start;
  final int end;
  final String text;
  final int startOffset;
  final int? endOffset;

  /// Null for highlights saved before the time was kept.
  final DateTime? created;

  /// The same on every device, so sync can match a highlight and its removal.
  String get key => created != null
      ? 'm${created!.millisecondsSinceEpoch}'
      : 'm$chapter:$start:$startOffset:$end:${endOffset ?? -1}';

  Map<String, Object> toJson() => {
        'chapter': chapter,
        'start': start,
        'end': end,
        'text': text,
        'startOffset': startOffset,
        if (endOffset != null) 'endOffset': endOffset!,
        if (created != null) 'created': created!.toUtc().toIso8601String(),
      };

  static HighlightMark? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final chapter = raw['chapter'];
    final start = raw['start'];
    final end = raw['end'];
    final text = raw['text'];
    if (chapter is! int || start is! int || end is! int || text is! String) return null;
    if (text.trim().isEmpty) return null;
    final startOffset = raw['startOffset'];
    final endOffset = raw['endOffset'];
    final created = raw['created'];
    return HighlightMark(
      chapter: chapter,
      start: start,
      end: end,
      text: text,
      startOffset: startOffset is int && startOffset >= 0 ? startOffset : 0,
      endOffset: endOffset is int && endOffset >= 0 ? endOffset : null,
      created: created is String ? DateTime.tryParse(created) : null,
    );
  }
}

/// Highlights in [chapter] that share at least one character with the range. [endOffset] is exclusive.
List<HighlightMark> marksOverlapping(
  Iterable<HighlightMark> marks, {
  required int chapter,
  required int startSid,
  required int startOffset,
  required int endSid,
  required int endOffset,
}) {
  int cmp(int sa, int oa, int sb, int ob) => sa != sb ? sa - sb : oa - ob;
  const sentenceEnd = 1 << 30;
  return [
    for (final mark in marks)
      if (mark.chapter == chapter &&
          cmp(startSid, startOffset, mark.end, mark.endOffset ?? sentenceEnd) < 0 &&
          cmp(mark.start, mark.startOffset, endSid, endOffset) < 0)
        mark,
  ];
}

/// A named place in the book. [sentenceId] is the first sentence there; without it, [page] is used.
class BookTag {
  const BookTag({
    required this.id,
    required this.chapter,
    required this.name,
    this.sentenceId,
    this.page = 0,
    this.updated,
  });

  /// Milliseconds since the epoch when the tag was made.
  final int id;
  final int chapter;
  final String name;
  final int? sentenceId;
  final int page;

  /// The last rename. Sync keeps the newer name.
  final DateTime? updated;

  String get key => 't$id';

  DateTime get changed => updated ?? DateTime.fromMillisecondsSinceEpoch(id);

  BookTag renamed(String value) => BookTag(
        id: id,
        chapter: chapter,
        name: value,
        sentenceId: sentenceId,
        page: page,
        updated: DateTime.now(),
      );

  Map<String, Object> toJson() => {
        'id': id,
        'chapter': chapter,
        'name': name,
        if (sentenceId != null) 'sentenceId': sentenceId!,
        'page': page,
        if (updated != null) 'updated': updated!.toUtc().toIso8601String(),
      };

  static BookTag? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final chapter = raw['chapter'];
    final name = raw['name'];
    final sentenceId = raw['sentenceId'];
    final page = raw['page'];
    final updated = raw['updated'];
    if (id is! int || chapter is! int || name is! String || name.trim().isEmpty) return null;
    return BookTag(
      id: id,
      chapter: chapter,
      name: name,
      sentenceId: sentenceId is int ? sentenceId : null,
      page: page is int ? page : 0,
      updated: updated is String ? DateTime.tryParse(updated) : null,
    );
  }
}

class ReaderStore extends ChangeNotifier {
  ReaderStore({SharedPreferences? preferences}) : _prefs = preferences;

  static const _key = 'reader_v1';

  SharedPreferences? _prefs;
  var layout = const ReaderLayout();
  var pace = SpeechPace.normal;
  var engine = SpeechEngine.system;
  var language = SpeechLanguage.cantonese;
  final Map<String, List<HighlightMark>> _marks = {};
  final Map<String, List<BookTag>> _tags = {};

  /// flutter_tts uses 0.5 as normal speed. These are 0.6, 0.8, 1, 1.25, and 1.5 times that.
  double get paceRate => switch (pace) {
        SpeechPace.slow => 0.3,
        SpeechPace.slower => 0.4,
        SpeechPace.normal => 0.5,
        SpeechPace.faster => 0.625,
        SpeechPace.fast => 0.75,
      };

  /// Screen brightness from 0 to 1 while reading. Null follows the system.
  double? brightness;

  /// Highlights and tags kept here before they moved to the per-book files. Read once, then dropped.
  List<HighlightMark> legacyMarks(String path) => List.unmodifiable(_marks[path] ?? const []);

  List<BookTag> legacyTags(String path) => List.unmodifiable(_tags[path] ?? const []);

  Future<void> dropLegacy(String path) async {
    final marks = _marks.remove(path);
    final tags = _tags.remove(path);
    if (marks == null && tags == null) return;
    await _save();
  }

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_key);
    if (raw == null) return;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return;
      layout = ReaderLayout.fromJson(json['layout']);
      pace = _enum(SpeechPace.values, json['pace'], SpeechPace.normal);
      engine = SpeechEngine.system;
      final savedLanguage = json['language'];
      language = savedLanguage is String
          ? _enum(SpeechLanguage.values, savedLanguage, SpeechLanguage.cantonese)
          : languageFromLocale(json['voiceLocale']) ?? SpeechLanguage.cantonese;
      final light = json['brightness'];
      brightness = light is num ? light.toDouble().clamp(0.0, 1.0) : null;
      final marks = json['marks'];
      if (marks is Map) {
        marks.forEach((key, value) {
          if (key is! String || value is! List) return;
          _marks[key] = [
            for (final item in value)
              if (HighlightMark.fromJson(item) != null) HighlightMark.fromJson(item)!,
          ];
        });
      }
      final tags = json['tags'];
      if (tags is Map) {
        tags.forEach((key, value) {
          if (key is! String || value is! List) return;
          _tags[key] = [
            for (final item in value)
              if (BookTag.fromJson(item) != null) BookTag.fromJson(item)!,
          ];
        });
      }
    } catch (_) {}
  }

  Future<void> setLayout(ReaderLayout value) async {
    layout = value;
    notifyListeners();
    await _save();
  }

  Future<void> setPace(SpeechPace value) async {
    pace = value;
    notifyListeners();
    await _save();
  }

  Future<void> setLanguage(SpeechLanguage value) async {
    language = value;
    notifyListeners();
    await _save();
  }

  Future<void> setBrightness(double? value) async {
    brightness = value?.clamp(0.0, 1.0);
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setString(_key, jsonEncode(_toJson()));
  }

  Map<String, Object?> _toJson() => {
        'layout': layout.toJson(),
        'pace': pace.name,
        'engine': engine.name,
        'language': language.name,
        if (brightness != null) 'brightness': brightness,
        'marks': {
          for (final entry in _marks.entries) entry.key: [for (final mark in entry.value) mark.toJson()],
        },
        'tags': {
          for (final entry in _tags.entries) entry.key: [for (final tag in entry.value) tag.toJson()],
        },
      };
}

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
