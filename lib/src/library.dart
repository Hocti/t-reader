import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'book_data.dart';
import 'book_files.dart';
import 'book_text.dart';
import 'cover_thumb.dart';
import 'drive_sync.dart';
import 'parse_epub.dart';
import 'reader_store.dart';
import 'scan.dart';
import 'screen.dart';
import 'theme.dart';

enum ShelfView { list, grid }

enum ShelfSort { lastRead, title, progress, modified }

/// When a lookup says the word aloud. [headphones] is the default.
enum LookupSpeak { headphones, always, never }

/// Which books the shelf lists. Only [archived] and [all] include archived books. Hidden books never show.
enum ShelfFilter { shelf, reading, unstarted, finished, archived, all }

/// At 100%, or at or past the chapter [endChapter] found.
bool bookFinished(ShelfBook book) {
  if (book.readProgress != null && book.readProgress! >= 0.999) return true;
  final end = book.endChapter;
  final at = book.chapterIndex;
  return end != null && at != null && at >= end;
}

bool bookUnstarted(ShelfBook book) => book.lastRead == null && book.readProgress == null && book.chapterIndex == null;

enum BookStatus { reading, unstarted, finished, archived }

BookStatus bookStatus(ShelfBook book) {
  if (book.archived) return BookStatus.archived;
  if (bookUnstarted(book)) return BookStatus.unstarted;
  if (bookFinished(book)) return BookStatus.finished;
  return BookStatus.reading;
}

bool bookPassesFilter(ShelfBook book, ShelfFilter filter) {
  if (book.hidden) return false;
  return switch (filter) {
    ShelfFilter.shelf => !book.archived,
    ShelfFilter.reading => !book.archived && !bookUnstarted(book) && !bookFinished(book),
    ShelfFilter.unstarted => !book.archived && bookUnstarted(book),
    ShelfFilter.finished => !book.archived && bookFinished(book),
    ShelfFilter.archived => book.archived,
    ShelfFilter.all => true,
  };
}

class ShelfBook {
  ShelfBook({
    required this.path,
    required this.zipped,
    required this.fallbackTitle,
    this.stamp = '',
  });

  final String path;
  final bool zipped;
  final String fallbackTitle;
  final String stamp;
  String? bookTitle;
  int chapterCount = 0;
  int? chapterIndex;
  int? sentenceId;
  int? page;
  double? readProgress;
  int? speechChapter;
  int? speechSentence;
  List<int>? weights;

  /// From [endChapter] in `book_text.dart`.
  int? endChapter;
  DateTime? lastRead;
  DateTime modified = DateTime.fromMillisecondsSinceEpoch(0);
  Uint8List? cover;
  bool archived = false;
  bool hidden = false;

  String get title {
    final inner = bookTitle?.trim();
    if (inner == null || inner.isEmpty) return fallbackTitle;
    return inner;
  }

  double get progress {
    final estimate = readProgress;
    if (estimate != null) return estimate.clamp(0.0, 1.0);
    if (chapterIndex == null || chapterCount <= 0) return 0;
    return chapterIndex!.clamp(0, chapterCount - 1) / chapterCount;
  }
}

class BookRecord {
  const BookRecord({
    this.chapterIndex,
    this.sentenceId,
    this.page,
    this.progress,
    this.speechChapter,
    this.speechSentence,
    this.lastRead,
    this.archived = false,
    this.hidden = false,
  });

  final int? chapterIndex;
  final int? sentenceId;
  final int? page;
  final double? progress;
  final int? speechChapter;
  final int? speechSentence;
  final DateTime? lastRead;
  final bool archived;
  final bool hidden;
}

/// What the shelf needs from inside a book. Kept until the file or folder changes.
class BookMeta {
  const BookMeta({
    required this.stamp,
    this.title,
    this.chapterCount = 0,
    this.coverFile,
    this.weights,
    this.endChapter,
    this.endKnown = false,
  });

  final String stamp;
  final String? title;
  final int chapterCount;
  final String? coverFile;
  final List<int>? weights;
  final int? endChapter;

  /// False for caches written before [endChapter] existed, so the book is read again.
  final bool endKnown;

  BookMeta withWeights(List<int> value) => BookMeta(
        stamp: stamp,
        title: title,
        chapterCount: chapterCount,
        coverFile: coverFile,
        weights: value,
        endChapter: endChapter,
        endKnown: endKnown,
      );

  Map<String, Object?> toJson() => {
        'stamp': stamp,
        'title': title,
        'chapterCount': chapterCount,
        'coverFile': coverFile,
        'weights': weights,
        if (endKnown) 'end': endChapter ?? -1,
      };

  static BookMeta? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final stamp = raw['stamp'];
    if (stamp is! String) return null;
    final title = raw['title'];
    final count = raw['chapterCount'];
    final cover = raw['coverFile'];
    final weights = raw['weights'];
    final end = raw['end'];
    return BookMeta(
      stamp: stamp,
      title: title is String ? title : null,
      chapterCount: count is int ? count : 0,
      coverFile: cover is String ? cover : null,
      weights: weights is List && weights.every((item) => item is int) ? weights.cast<int>() : null,
      endChapter: end is int && end >= 0 ? end : null,
      endKnown: end is int,
    );
  }
}

String? formatReadTime(DateTime? time) {
  if (time == null) return null;
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

String? progressLabel(ShelfBook book) {
  if (book.readProgress == null && (book.chapterIndex == null || book.chapterCount <= 0)) return null;
  return '${(book.progress * 100).floor()}%';
}

class ShelfNotice {
  const ShelfNotice(this.key);

  final String key;
}

ShelfNotice? emptyShelfNotice({
  required int directories,
  required int books,
  required int visible,
  required int missing,
  required int unreadable,
  ShelfFilter filter = ShelfFilter.shelf,
}) {
  if (directories == 0 && books == 0) return const ShelfNotice('shelf.empty_no_dir');
  if (books == 0) {
    if (missing == directories) {
      return ShelfNotice(directories == 1 ? 'shelf.empty_missing_one' : 'shelf.empty_missing_many');
    }
    if (unreadable == directories) {
      return ShelfNotice(directories == 1 ? 'shelf.empty_unreadable_one' : 'shelf.empty_unreadable_many');
    }
    return ShelfNotice(directories == 1 ? 'shelf.empty_one' : 'shelf.empty_many');
  }
  if (visible == 0) {
    return ShelfNotice(filter == ShelfFilter.shelf ? 'shelf.empty_filtered' : 'shelf.empty_filter_none');
  }
  return null;
}

/// Books whose title, or file or folder name, contains [query]. Case and spaces are ignored.
List<ShelfBook> filterBooks(List<ShelfBook> books, String query) {
  String fold(String value) => value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  final needle = fold(query);
  if (needle.isEmpty) return books;
  return [
    for (final book in books)
      if (fold(book.title).contains(needle) || fold(book.fallbackTitle).contains(needle)) book,
  ];
}

int compareBooks(ShelfBook a, ShelfBook b, ShelfSort sort) {
  late final int primary;
  switch (sort) {
    case ShelfSort.lastRead:
      if (a.lastRead == null && b.lastRead == null) {
        primary = 0;
      } else if (a.lastRead == null) {
        primary = 1;
      } else if (b.lastRead == null) {
        primary = -1;
      } else {
        primary = b.lastRead!.compareTo(a.lastRead!);
      }
    case ShelfSort.title:
      primary = a.title.compareTo(b.title);
    case ShelfSort.progress:
      primary = b.progress.compareTo(a.progress);
    case ShelfSort.modified:
      primary = b.modified.compareTo(a.modified);
  }
  if (primary != 0) return primary;
  final byTitle = a.title.compareTo(b.title);
  if (byTitle != 0) return byTitle;
  return a.path.compareTo(b.path);
}

class LibraryController extends ChangeNotifier {
  LibraryController({SharedPreferences? preferences, DriveSync? drive})
      : _prefs = preferences,
        drive = drive ?? DriveSync();

  static const _key = 'library_v1';
  static const _metaKey = 'book_meta_v1';

  SharedPreferences? _prefs;
  var _disposed = false;
  var _generation = 0;

  AppThemeKind theme = AppThemeKind.einkWhite;
  ShelfView view = ShelfView.list;
  ShelfSort sort = ShelfSort.lastRead;
  var uiLanguage = 'zh-Hant';
  ShelfFilter filter = ShelfFilter.shelf;
  LookupSpeak lookupSpeak = LookupSpeak.headphones;
  List<String> directories = [];

  /// Keeps the screen awake while a book is open.
  var keepAwake = false;

  /// Opens [readingNow] when the app starts.
  var openLast = true;

  /// The book on screen. Cleared when the reader closes, so it survives only when the app is closed from the reader.
  String? readingNow;
  ScreenTurn screenTurn = ScreenTurn.auto;

  /// Where the per-book files live. Null is the app's own storage.
  String? dataDir;
  var driveOn = false;
  String? driveAccount;
  DateTime? driveSynced;

  /// A `strings.csv` key for the last sync failure.
  String? driveError;
  var driveBusy = false;
  final DriveSync drive;
  late final BookDataStore data = BookDataStore()..onWritten = _dataWritten;
  Timer? _syncTimer;
  var _syncAgain = false;

  /// `.epub` files opened from another app. They stay on the shelf outside the book folders.
  List<String> openedFiles = [];
  List<ShelfBook> books = [];
  List<String> missing = [];
  List<String> unreadable = [];
  final Map<String, BookRecord> _records = {};
  final Map<String, BookMeta> _meta = {};
  Future<Directory?>? _coverDir;

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_key);
    if (raw != null) {
      try {
        _readJson(jsonDecode(raw));
      } catch (_) {}
    }
    final rawMeta = _prefs!.getString(_metaKey);
    if (rawMeta != null) {
      try {
        final json = jsonDecode(rawMeta);
        if (json is Map) {
          json.forEach((key, value) {
            final meta = BookMeta.fromJson(value);
            if (key is String && meta != null) _meta[key] = meta;
          });
        }
      } catch (_) {}
    }
    data.customDir = dataDir;
    await rescan();
    if (driveOn) unawaited(syncNow());
  }

  Future<void> rescan() async {
    final generation = ++_generation;
    final scan = scanDirectories(directories);
    final opened = scanFiles(openedFiles, skip: {for (final book in scan.books) book.path});
    if (generation != _generation || _disposed) return;
    final previous = {for (final book in books) book.path: book};
    final next = <ShelfBook>[];
    for (final location in [...scan.books, ...opened]) {
      final book = ShelfBook(
        path: location.path,
        zipped: location.zipped,
        fallbackTitle: location.fallbackTitle,
        stamp: location.stamp,
      );
      book.modified = location.modified;
      final old = previous[location.path];
      if (old != null) {
        book.bookTitle = old.bookTitle;
        book.chapterCount = old.chapterCount;
        book.endChapter = old.endChapter;
        if (old.stamp == book.stamp) {
          book.cover = old.cover;
          book.weights = old.weights;
        }
      }
      _applyRecord(book);
      next.add(book);
    }
    books = next;
    missing = scan.missing;
    unreadable = scan.unreadable;
    _notify();

    var metaChanged = false;
    for (final book in next) {
      final cached = _meta[book.path];
      var fresh = cached != null && cached.stamp == book.stamp && cached.endKnown;
      if (fresh) {
        book.bookTitle = cached.title;
        book.chapterCount = cached.chapterCount;
        book.weights = cached.weights;
        book.endChapter = cached.endChapter;
        if (cached.coverFile != null && book.cover == null) {
          book.cover = await _loadCover(cached.coverFile!);
          if (book.cover == null) fresh = false;
        }
      }
      if (!fresh) {
        final meta = await _readMeta(book);
        if (generation != _generation || _disposed) return;
        book.bookTitle = meta.title;
        book.chapterCount = meta.chapterCount;
        book.cover = meta.cover;
        book.endChapter = meta.endChapter;
        final keepWeights = cached != null && cached.stamp == book.stamp ? cached.weights : null;
        book.weights = keepWeights;
        _meta[book.path] = BookMeta(
          stamp: book.stamp,
          title: meta.title,
          chapterCount: meta.chapterCount,
          coverFile: meta.coverFile,
          weights: keepWeights,
          endChapter: meta.endChapter,
          endKnown: true,
        );
        metaChanged = true;
      }
      if (generation != _generation || _disposed) return;
      await _applyData(book);
      if (generation != _generation || _disposed) return;
      if (book.chapterIndex != null && book.chapterCount > 0) {
        book.chapterIndex = book.chapterIndex!.clamp(0, book.chapterCount - 1);
        _writeRecord(book);
      }
      _notify();
    }
    await _save();
    if (metaChanged) await _saveMeta();
  }

  BookMeta? metaFor(String path) {
    final book = bookByPath(path);
    final meta = _meta[path];
    if (book == null || meta == null || meta.stamp != book.stamp) return null;
    return meta;
  }

  /// Chapter weights are measured the first time a book is opened.
  Future<void> setWeights(String path, List<int> weights) async {
    final book = bookByPath(path);
    if (book == null) return;
    book.weights = weights;
    final meta = _meta[path];
    _meta[path] = meta != null && meta.stamp == book.stamp
        ? meta.withWeights(weights)
        : BookMeta(
            stamp: book.stamp,
            title: book.bookTitle,
            chapterCount: weights.length,
            weights: weights,
            endChapter: book.endChapter,
          );
    await _saveMeta();
  }

  void setTheme(AppThemeKind value) {
    theme = value;
    _notify();
    unawaited(_save());
  }

  void setView(ShelfView value) {
    view = value;
    _notify();
    unawaited(_save());
  }

  void setSort(ShelfSort value) {
    sort = value;
    _notify();
    unawaited(_save());
  }

  void setUiLanguage(String value) {
    if (value.isEmpty) return;
    uiLanguage = value;
    _notify();
    unawaited(_save());
  }

  void setLookupSpeak(LookupSpeak value) {
    lookupSpeak = value;
    _notify();
    unawaited(_save());
  }

  void setFilter(ShelfFilter value) {
    filter = value;
    _notify();
    unawaited(_save());
  }

  void setKeepAwake(bool value) {
    keepAwake = value;
    _notify();
    unawaited(_save());
  }

  void setOpenLast(bool value) {
    openLast = value;
    _notify();
    unawaited(_save());
  }

  /// Saved without a rebuild, since the reader calls it while it opens and closes.
  void setReadingNow(String? path) {
    if (readingNow == path) return;
    readingNow = path;
    unawaited(_save());
  }

  void setScreenTurn(ScreenTurn value) {
    screenTurn = value;
    unawaited(applyScreenTurn(value));
    _notify();
    unawaited(_save());
  }

  /// Moves the per-book files to [path], or back to app storage when it is null.
  Future<void> setDataDir(String? path) async {
    final stored = path == null ? null : canonicalPath(path);
    if (stored == dataDir) return;
    await data.setDirectory(stored);
    dataDir = stored;
    _notify();
    await _save();
    await _reapplyData();
    if (driveOn) unawaited(syncNow());
  }

  Future<void> connectDrive() async {
    driveError = null;
    driveBusy = true;
    _notify();
    try {
      final email = await drive.connect();
      driveBusy = false;
      if (email == null) {
        _notify();
        return;
      }
      driveOn = true;
      driveAccount = email;
      await _save();
    } on DriveException catch (error) {
      driveBusy = false;
      driveError = error.key;
      _notify();
      return;
    }
    await syncNow();
  }

  Future<void> disconnectDrive() async {
    _syncTimer?.cancel();
    await drive.disconnect();
    driveOn = false;
    driveAccount = null;
    driveSynced = null;
    driveError = null;
    _notify();
    await _save();
  }

  /// One sync at a time. A change during a sync starts another one after it.
  Future<void> syncNow() async {
    if (!driveOn || _disposed) return;
    if (driveBusy) {
      _syncAgain = true;
      return;
    }
    _syncTimer?.cancel();
    driveBusy = true;
    driveError = null;
    _notify();
    try {
      final changed = await drive.sync(data);
      driveSynced = DateTime.now();
      driveAccount = drive.email ?? driveAccount;
      if (changed.isNotEmpty) await _reapplyData(changed);
    } on DriveException catch (error) {
      driveError = error.key;
    } catch (_) {
      driveError = 'drive.failed';
    }
    driveBusy = false;
    _notify();
    unawaited(_save());
    if (_syncAgain) {
      _syncAgain = false;
      _scheduleSync();
    }
  }

  /// The app went to the background: write the files now and send them.
  Future<void> onPause() async {
    await data.flush();
    if (driveOn) await syncNow();
  }

  void onResume() {
    if (driveOn) unawaited(syncNow());
  }

  void _dataWritten() {
    if (driveOn) _scheduleSync();
  }

  void _scheduleSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(seconds: 8), () => unawaited(syncNow()));
  }

  /// Takes the newer reading place from the files named in [names], or from every file.
  Future<void> _reapplyData([Set<String>? names]) async {
    for (final book in books) {
      if (names != null && !names.contains(bookDataFileName(book.title))) continue;
      final record = await data.load(book.title);
      if (_takeData(book, record)) _writeRecord(book);
    }
    _notify();
    await _save();
  }

  /// The file wins when it was read later. Otherwise a newer local place goes into the file.
  Future<void> _applyData(ShelfBook book) async {
    final record = await data.load(book.title);
    if (_takeData(book, record)) {
      _writeRecord(book);
      return;
    }
    final mine = book.lastRead;
    if (mine != null && (record.lastRead == null || mine.isAfter(record.lastRead!))) {
      _fillData(record, book);
      data.save(record);
    }
  }

  bool _takeData(ShelfBook book, BookData record) {
    final time = record.lastRead;
    if (time == null) return false;
    if (book.lastRead != null && !time.isAfter(book.lastRead!)) return false;
    book
      ..chapterIndex = record.chapter
      ..sentenceId = record.sentenceId
      ..page = record.page
      ..readProgress = record.progress
      ..speechChapter = record.speechChapter
      ..speechSentence = record.speechSentence
      ..lastRead = time;
    return true;
  }

  void _fillData(BookData record, ShelfBook book) {
    record
      ..chapter = book.chapterIndex
      ..sentenceId = book.sentenceId
      ..page = book.page
      ..progress = book.readProgress
      ..speechChapter = book.speechChapter
      ..speechSentence = book.speechSentence
      ..lastRead = book.lastRead;
  }

  void _saveData(ShelfBook book) {
    final loaded = data.peek(book.title);
    if (loaded != null) {
      _fillData(loaded, book);
      data.save(loaded);
      return;
    }
    unawaited(data.load(book.title).then((record) {
      _fillData(record, book);
      data.save(record);
    }));
  }

  /// The title each open book's file is under. A book opened before the shelf lists it uses the title inside it.
  final Map<String, String> _dataTitles = {};

  String? _titleFor(String path) => bookByPath(path)?.title ?? _dataTitles[path];

  BookData? _loaded(String path) {
    final title = _titleFor(path);
    return title == null ? null : data.peek(title);
  }

  /// Loads the book's file before the reader shows it, and moves in highlights and tags that older
  /// versions kept on this device only.
  Future<void> openData(
    String path, {
    String? title,
    List<HighlightMark> legacyMarks = const [],
    List<BookTag> legacyTags = const [],
  }) async {
    final book = bookByPath(path);
    if (book != null && book.bookTitle == null && title != null && title.trim().isNotEmpty) book.bookTitle = title;
    final name = book?.title ?? title;
    if (name == null) return;
    _dataTitles[path] = name;
    final record = await data.load(name);
    if (legacyMarks.isEmpty && legacyTags.isEmpty) return;
    final merged = BookData.merge(record, BookData(name)
      ..marks = [...legacyMarks]
      ..tags = [...legacyTags]);
    record
      ..marks = merged.marks
      ..tags = merged.tags;
    data.save(record);
    _notify();
  }

  List<HighlightMark> marksFor(String path) => List.unmodifiable(_loaded(path)?.marks ?? const <HighlightMark>[]);

  List<BookTag> tagsFor(String path) => List.unmodifiable(_loaded(path)?.tags ?? const <BookTag>[]);

  void addMark(String path, HighlightMark mark) {
    final record = _loaded(path);
    if (record == null) return;
    record.marks = [...record.marks, mark];
    record.tidy();
    data.save(record);
    _notify();
  }

  void removeMarks(String path, Iterable<HighlightMark> marks) {
    final record = _loaded(path);
    if (record == null) return;
    final now = DateTime.now();
    for (final mark in marks) {
      record.removed[mark.key] = now;
    }
    record.tidy();
    data.save(record);
    _notify();
  }

  void addTag(String path, BookTag tag) {
    final record = _loaded(path);
    if (record == null) return;
    record.tags = [...record.tags, tag];
    record.tidy();
    data.save(record);
    _notify();
  }

  /// Replaces the tag with the same id. A null [tag] removes the one with [id].
  void updateTag(String path, int id, BookTag? tag) {
    final record = _loaded(path);
    if (record == null) return;
    if (tag == null) {
      record.removed['t$id'] = DateTime.now();
    } else {
      record.tags = [
        for (final item in record.tags)
          if (item.id == id) tag else item,
      ];
    }
    record.tidy();
    data.save(record);
    _notify();
  }

  Future<void> addDirectory(String path) async {
    final stored = canonicalPath(path);
    final type = FileSystemEntity.typeSync(stored);
    if (type != FileSystemEntityType.directory) return;
    if (directories.contains(stored)) return;
    directories = [...directories, stored];
    _notify();
    await rescan();
  }

  /// Puts a file opened from another app on the shelf. The shelf lists it at once; the cover follows.
  void addOpenedFile(String path) {
    final stored = canonicalPath(path);
    if (!openedFiles.contains(stored)) openedFiles = [...openedFiles, stored];
    unawaited(rescan());
    unawaited(_save());
  }

  Future<void> removeDirectory(String path) async {
    directories = [
      for (final item in directories)
        if (item != path) item,
    ];
    _notify();
    await rescan();
  }

  void setArchived(String path, bool archived) {
    final book = bookByPath(path);
    if (book == null || book.hidden) return;
    book.archived = archived;
    _writeRecord(book);
    _notify();
    unawaited(_save());
  }

  void setHidden(String path, bool hidden) {
    final book = bookByPath(path);
    if (book == null) return;
    book.hidden = hidden;
    if (hidden) book.archived = false;
    _writeRecord(book);
    _notify();
    unawaited(_save());
  }

  void rememberChapter(String path, int index) {
    final book = bookByPath(path);
    if (book == null) return;
    if (book.chapterIndex != index) {
      book.sentenceId = null;
      book.page = null;
    }
    book.chapterIndex = index;
    book.lastRead = DateTime.now();
    _writeRecord(book);
    _saveData(book);
    _notify();
    unawaited(_save());
  }

  void rememberPosition(
    String path, {
    required int chapter,
    required int? sentenceId,
    required int page,
    required double progress,
  }) {
    final book = bookByPath(path);
    if (book == null) return;
    book.chapterIndex = chapter;
    book.sentenceId = sentenceId;
    book.page = page;
    book.readProgress = progress;
    book.lastRead = DateTime.now();
    _writeRecord(book);
    _saveData(book);
    _notify();
    unawaited(_save());
  }

  /// Where speech last was, kept after it stops.
  void rememberSpeech(String path, int chapter, int sentenceId) {
    final book = bookByPath(path);
    if (book == null) return;
    if (book.speechChapter == chapter && book.speechSentence == sentenceId) return;
    book.speechChapter = chapter;
    book.speechSentence = sentenceId;
    _writeRecord(book);
    _saveData(book);
    unawaited(_save());
  }

  ShelfBook? bookByPath(String path) {
    for (final book in books) {
      if (book.path == path) return book;
    }
    return null;
  }

  List<ShelfBook> get visibleBooks {
    final list = books.where((book) => bookPassesFilter(book, filter)).toList();
    list.sort((a, b) => compareBooks(a, b, sort));
    return list;
  }

  List<ShelfBook> get hiddenBooks {
    final list = books.where((book) => book.hidden).toList();
    list.sort((a, b) => compareBooks(a, b, ShelfSort.title));
    return list;
  }

  @override
  void dispose() {
    _disposed = true;
    _syncTimer?.cancel();
    super.dispose();
  }

  void _applyRecord(ShelfBook book) {
    final record = _records[book.path];
    if (record == null) return;
    book.chapterIndex = record.chapterIndex;
    book.sentenceId = record.sentenceId;
    book.page = record.page;
    book.readProgress = record.progress;
    book.speechChapter = record.speechChapter;
    book.speechSentence = record.speechSentence;
    book.lastRead = record.lastRead;
    book.archived = record.archived;
    book.hidden = record.hidden;
  }

  void _writeRecord(ShelfBook book) {
    _records[book.path] = BookRecord(
      chapterIndex: book.chapterIndex,
      sentenceId: book.sentenceId,
      page: book.page,
      progress: book.readProgress,
      speechChapter: book.speechChapter,
      speechSentence: book.speechSentence,
      lastRead: book.lastRead,
      archived: book.archived,
      hidden: book.hidden,
    );
  }

  Future<({String? title, int chapterCount, Uint8List? cover, String? coverFile, int? endChapter})> _readMeta(
    ShelfBook book,
  ) async {
    try {
      final BookFiles files = book.zipped
          ? await openZipBook(book.path)
          : DirectoryBookFiles(book.path);
      final parsed = await parseBook(files);
      Uint8List? cover;
      String? coverFile;
      final coverPath = parsed.coverPath;
      if (coverPath != null) {
        final bytes = await files.read(coverPath);
        if (bytes != null && bytes.isNotEmpty) {
          cover = await makeCoverThumbnail(Uint8List.fromList(bytes));
          coverFile = await _storeCover(book, cover);
        }
      }
      return (
        title: parsed.title,
        chapterCount: parsed.chapters.length,
        cover: cover,
        coverFile: coverFile,
        endChapter: endChapter([for (final chapter in parsed.chapters) chapter.label]),
      );
    } catch (_) {
      return (title: null, chapterCount: 0, cover: null, coverFile: null, endChapter: null);
    }
  }

  Future<Directory?> _covers() {
    return _coverDir ??= () async {
      try {
        final base = await getApplicationSupportDirectory();
        final dir = Directory(p.join(base.path, 'covers'));
        await dir.create(recursive: true);
        return dir;
      } catch (_) {
        return null;
      }
    }();
  }

  Future<String?> _storeCover(ShelfBook book, Uint8List bytes) async {
    final dir = await _covers();
    if (dir == null) return null;
    final name = '${_pathHash(book.path)}.img';
    try {
      await File(p.join(dir.path, name)).writeAsBytes(bytes, flush: true);
      return name;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _loadCover(String name) async {
    final dir = await _covers();
    if (dir == null) return null;
    try {
      final file = File(p.join(dir.path, name));
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    final prefs = _prefs;
    if (prefs == null || _disposed) return;
    await prefs.setString(_key, jsonEncode(_toJson()));
  }

  Future<void> _saveMeta() async {
    final prefs = _prefs;
    if (prefs == null || _disposed) return;
    await prefs.setString(_metaKey, jsonEncode({for (final entry in _meta.entries) entry.key: entry.value.toJson()}));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Map<String, Object?> _toJson() {
    return {
      'theme': theme.name,
      'view': view.name,
      'sort': sort.name,
      'uiLanguage': uiLanguage,
      'filter': filter.name,
      'lookupSpeak': lookupSpeak.name,
      'directories': directories,
      'openedFiles': openedFiles,
      'keepAwake': keepAwake,
      'openLast': openLast,
      'readingNow': readingNow,
      'screenTurn': screenTurn.name,
      'dataDir': dataDir,
      'driveOn': driveOn,
      'driveAccount': driveAccount,
      'driveSynced': driveSynced?.toIso8601String(),
      'books': {
        for (final entry in _records.entries)
          entry.key: {
            'chapterIndex': entry.value.chapterIndex,
            'sentenceId': entry.value.sentenceId,
            'page': entry.value.page,
            'progress': entry.value.progress,
            'speechChapter': entry.value.speechChapter,
            'speechSentence': entry.value.speechSentence,
            'lastRead': entry.value.lastRead?.toIso8601String(),
            'archived': entry.value.archived,
            'hidden': entry.value.hidden,
          },
      },
    };
  }

  void _readJson(Object? raw) {
    if (raw is! Map) return;
    theme = themeKindFromName(raw['theme'] as String?);
    view = raw['view'] == 'grid' ? ShelfView.grid : ShelfView.list;
    sort = switch (raw['sort']) {
      'title' => ShelfSort.title,
      'progress' => ShelfSort.progress,
      // The shelf no longer offers this sort; a saved one falls back to last read.
      // 'modified' => ShelfSort.modified,
      _ => ShelfSort.lastRead,
    };
    final storedLanguage = raw['uiLanguage'];
    if (storedLanguage is String && storedLanguage.isNotEmpty) uiLanguage = storedLanguage;
    final storedFilter = raw['filter'];
    filter = ShelfFilter.values.firstWhere(
      (value) => value.name == storedFilter,
      orElse: () => raw['showArchived'] == true ? ShelfFilter.archived : ShelfFilter.shelf,
    );
    keepAwake = raw['keepAwake'] == true;
    openLast = raw['openLast'] != false;
    final storedReading = raw['readingNow'];
    readingNow = storedReading is String && storedReading.isNotEmpty ? storedReading : null;
    screenTurn = ScreenTurn.values.firstWhere((value) => value.name == raw['screenTurn'], orElse: () => ScreenTurn.auto);
    final storedDataDir = raw['dataDir'];
    dataDir = storedDataDir is String && storedDataDir.isNotEmpty ? storedDataDir : null;
    driveOn = raw['driveOn'] == true;
    final storedAccount = raw['driveAccount'];
    driveAccount = storedAccount is String ? storedAccount : null;
    final storedSynced = raw['driveSynced'];
    driveSynced = storedSynced is String ? DateTime.tryParse(storedSynced) : null;
    lookupSpeak = LookupSpeak.values.firstWhere(
      (value) => value.name == raw['lookupSpeak'],
      orElse: () => LookupSpeak.headphones,
    );
    final storedDirectories = raw['directories'];
    if (storedDirectories is List) {
      directories = [
        for (final item in storedDirectories)
          if (item is String && item.isNotEmpty) item,
      ];
    }
    final storedOpened = raw['openedFiles'];
    if (storedOpened is List) {
      openedFiles = [
        for (final item in storedOpened)
          if (item is String && item.isNotEmpty) item,
      ];
    }
    final storedBooks = raw['books'];
    if (storedBooks is! Map) return;
    storedBooks.forEach((key, value) {
      if (key is! String || value is! Map) return;
      DateTime? lastRead;
      final rawTime = value['lastRead'];
      if (rawTime is String) lastRead = DateTime.tryParse(rawTime);
      final index = value['chapterIndex'];
      final progress = value['progress'];
      int? whole(String name) => value[name] is int ? value[name] as int : null;
      _records[key] = BookRecord(
        chapterIndex: index is int ? index : null,
        sentenceId: whole('sentenceId'),
        page: whole('page'),
        progress: progress is num ? progress.toDouble() : null,
        speechChapter: whole('speechChapter'),
        speechSentence: whole('speechSentence'),
        lastRead: lastRead,
        archived: value['archived'] == true,
        hidden: value['hidden'] == true,
      );
    });
  }
}

/// FNV-1a, so a cover file name does not depend on the path's characters.
String _pathHash(String path) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(path)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
