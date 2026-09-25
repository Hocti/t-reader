import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'reader_store.dart';

/// One book's reading place, highlights, and tags. Saved as one JSON file named after the book's
/// title, so the same book on another device, at another path, finds the same file.
class BookData {
  BookData(this.title);

  final String title;
  int? chapter;
  int? sentenceId;
  int? page;
  double? progress;
  DateTime? lastRead;
  int? speechChapter;
  int? speechSentence;
  List<HighlightMark> marks = [];
  List<BookTag> tags = [];

  /// Keys of removed highlights and tags, with the time of removal, so a sync does not bring them back.
  Map<String, DateTime> removed = {};

  Map<String, Object?> toJson() => {
        'version': 1,
        'title': title,
        'position': {
          'chapter': chapter,
          'sentenceId': sentenceId,
          'page': page,
          'progress': progress,
          'lastRead': lastRead?.toUtc().toIso8601String(),
          'speechChapter': speechChapter,
          'speechSentence': speechSentence,
        },
        'marks': [for (final mark in marks) mark.toJson()],
        'tags': [for (final tag in tags) tag.toJson()],
        'removed': {for (final entry in removed.entries) entry.key: entry.value.toUtc().toIso8601String()},
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static BookData? decode(String text, {String? title}) {
    try {
      return fromJson(jsonDecode(text), title: title);
    } catch (_) {
      return null;
    }
  }

  static BookData? fromJson(Object? raw, {String? title}) {
    if (raw is! Map) return null;
    final name = raw['title'] is String ? raw['title'] as String : title;
    if (name == null) return null;
    final data = BookData(name);
    final position = raw['position'];
    if (position is Map) {
      int? whole(String key) => position[key] is int ? position[key] as int : null;
      data.chapter = whole('chapter');
      data.sentenceId = whole('sentenceId');
      data.page = whole('page');
      final progress = position['progress'];
      data.progress = progress is num ? progress.toDouble() : null;
      final time = position['lastRead'];
      data.lastRead = time is String ? DateTime.tryParse(time) : null;
      data.speechChapter = whole('speechChapter');
      data.speechSentence = whole('speechSentence');
    }
    final marks = raw['marks'];
    if (marks is List) {
      data.marks = [
        for (final item in marks)
          if (HighlightMark.fromJson(item) != null) HighlightMark.fromJson(item)!,
      ];
    }
    final tags = raw['tags'];
    if (tags is List) {
      data.tags = [
        for (final item in tags)
          if (BookTag.fromJson(item) != null) BookTag.fromJson(item)!,
      ];
    }
    final removed = raw['removed'];
    if (removed is Map) {
      removed.forEach((key, value) {
        final time = value is String ? DateTime.tryParse(value) : null;
        if (key is String && time != null) data.removed[key] = time;
      });
    }
    data.tidy();
    return data;
  }

  /// A fixed order, so the same content always writes the same file.
  void tidy() {
    marks = [
      for (final mark in marks)
        if (!removed.containsKey(mark.key)) mark,
    ]..sort(_markOrder);
    tags = [
      for (final tag in tags)
        if (!removed.containsKey(tag.key)) tag,
    ]..sort((a, b) => a.id.compareTo(b.id));
  }

  /// The later reading place, every highlight and tag that neither side removed, and the newer tag name.
  static BookData merge(BookData a, BookData b) {
    final out = BookData(a.title);
    final later = b.lastRead != null && (a.lastRead == null || b.lastRead!.isAfter(a.lastRead!)) ? b : a;
    out
      ..chapter = later.chapter
      ..sentenceId = later.sentenceId
      ..page = later.page
      ..progress = later.progress
      ..lastRead = later.lastRead
      ..speechChapter = later.speechChapter
      ..speechSentence = later.speechSentence;
    out.removed = {...a.removed};
    b.removed.forEach((key, time) {
      final old = out.removed[key];
      if (old == null || time.isAfter(old)) out.removed[key] = time;
    });
    final marks = <String, HighlightMark>{for (final mark in a.marks) mark.key: mark};
    for (final mark in b.marks) {
      marks.putIfAbsent(mark.key, () => mark);
    }
    final tags = <String, BookTag>{for (final tag in a.tags) tag.key: tag};
    for (final tag in b.tags) {
      final mine = tags[tag.key];
      if (mine == null || tag.changed.isAfter(mine.changed)) tags[tag.key] = tag;
    }
    out.marks = marks.values.toList();
    out.tags = tags.values.toList();
    out.tidy();
    return out;
  }
}

int _markOrder(HighlightMark a, HighlightMark b) {
  var order = a.chapter.compareTo(b.chapter);
  if (order != 0) return order;
  order = a.start.compareTo(b.start);
  if (order != 0) return order;
  order = a.startOffset.compareTo(b.startOffset);
  if (order != 0) return order;
  return a.key.compareTo(b.key);
}

/// The book's title as a file name. Characters that file systems or Google Drive reject become `_`.
String bookDataFileName(String title) {
  var name = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
  while (name.startsWith('.')) {
    name = name.substring(1);
  }
  if (name.isEmpty) name = 'untitled';
  if (name.length > 120) name = name.substring(0, 120).trim();
  return '$name.json';
}

/// The per-book files, all in one folder. Writes wait a moment so page turns do not each write a file.
class BookDataStore {
  BookDataStore({this.customDir});

  /// Null keeps the files in the app's own storage.
  String? customDir;
  Future<Directory?>? _dir;
  final Map<String, BookData> _cache = {};
  final Map<String, Timer> _pending = {};

  /// Called after a local change reaches the disk. Sync uses it to send the file.
  void Function()? onWritten;

  static const _delay = Duration(milliseconds: 600);

  Future<Directory?> directory() {
    return _dir ??= () async {
      try {
        final path = customDir ?? p.join((await getApplicationSupportDirectory()).path, 'book-data');
        final dir = Directory(path);
        await dir.create(recursive: true);
        return dir;
      } catch (_) {
        return null;
      }
    }();
  }

  BookData? peek(String title) => _cache[bookDataFileName(title)];

  Future<BookData> load(String title) async {
    final name = bookDataFileName(title);
    final cached = _cache[name];
    if (cached != null) return cached;
    final read = await _read(name);
    return _cache[name] ??= read ?? BookData(title);
  }

  void save(BookData data) {
    final name = bookDataFileName(data.title);
    _cache[name] = data;
    _pending[name]?.cancel();
    _pending[name] = Timer(_delay, () => unawaited(_write(name, notify: true)));
  }

  /// Writes every waiting change now.
  Future<void> flush() async {
    final names = _pending.keys.toList();
    for (final name in names) {
      _pending.remove(name)?.cancel();
      await _write(name, notify: true, pendingDone: true);
    }
  }

  Future<List<String>> fileNames() async {
    final dir = await directory();
    if (dir == null) return const [];
    try {
      return [
        for (final entity in dir.listSync(followLinks: false))
          if (entity is File && entity.path.toLowerCase().endsWith('.json')) p.basename(entity.path),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// The file as it is now, from memory when it is loaded.
  Future<BookData?> readFile(String name) async => _cache[name] ?? await _read(name);

  /// Folds [incoming] into what is here and writes it. Used by sync, so it does not call [onWritten].
  Future<BookData> put(String name, BookData incoming) async {
    final here = _cache[name] ?? await _read(name);
    final merged = here == null ? incoming : BookData.merge(here, incoming);
    _cache[name] = merged;
    _pending.remove(name)?.cancel();
    await _write(name, notify: false, pendingDone: true);
    return merged;
  }

  /// Moves every file to [path], or back to app storage when it is null. Files already there are merged.
  Future<void> setDirectory(String? path) async {
    await flush();
    final oldNames = await fileNames();
    final old = <String, BookData>{};
    for (final name in oldNames) {
      final data = await readFile(name);
      if (data != null) old[name] = data;
    }
    customDir = path;
    _dir = null;
    _cache.clear();
    for (final entry in old.entries) {
      await put(entry.key, entry.value);
    }
  }

  Future<BookData?> _read(String name) async {
    final dir = await directory();
    if (dir == null) return null;
    try {
      final file = File(p.join(dir.path, name));
      if (!await file.exists()) return null;
      return BookData.decode(await file.readAsString(), title: p.basenameWithoutExtension(name));
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String name, {required bool notify, bool pendingDone = false}) async {
    if (!pendingDone) _pending.remove(name);
    final data = _cache[name];
    final dir = await directory();
    if (data == null || dir == null) return;
    try {
      final file = File(p.join(dir.path, name));
      final temp = File('${file.path}.part');
      await temp.writeAsString(data.encode(), flush: true);
      await temp.rename(file.path);
    } catch (_) {
      return;
    }
    if (notify) onWritten?.call();
  }
}
