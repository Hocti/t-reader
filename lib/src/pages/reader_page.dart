import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../book_files.dart';
import '../book_server.dart';
import '../book_text.dart';
import '../nav_link.dart';
import '../page_paint.dart';
import '../parse_epub.dart';
import '../reader_bridge.dart';
import '../reader_store.dart';
import '../screen.dart';
import '../sentences.dart';
import '../book_path.dart';
import '../library.dart';
import '../library_scope.dart';
import '../lookup.dart';
import '../lookup_sheet.dart';
import '../i18n.dart';
import '../speech_media.dart';
import '../widgets.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({required this.path, super.key});

  final String path;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _TempMark {
  const _TempMark({required this.chapter, required this.page, this.sentenceId});

  final int chapter;
  final int page;
  final int? sentenceId;
}

/// A selection from one character boundary to another. The end is exclusive.
class _Pick {
  const _Pick({
    required this.startSid,
    required this.startOffset,
    required this.endSid,
    required this.endOffset,
    required this.text,
  });

  final int startSid;
  final int startOffset;
  final int endSid;
  final int endOffset;
  final String text;
}

enum _Panel { layout, toc, search, brightness, turn }

enum _TocTab { contents, marks, tags, images }

/// The first place an image appears. [index] counts `img` and SVG `image` elements in its chapter.
class _BookImage {
  const _BookImage({required this.chapter, required this.index, required this.path});

  final int chapter;
  final int index;
  final String path;
}

class _ReaderPageState extends State<ReaderPage> {
  final _store = ReaderStore();
  BookServer? _server;
  WebViewController? _controller;
  List<ChapterRef> _chapters = const [];
  List<TocEntry> _toc = const [];
  Map<String, int> _spineIndex = const {};
  List<Sentence> _sentences = const [];
  final _headings = <int, List<ChapterHeading>>{};
  _TempMark? _temp;
  final _tocOpen = <int>{};
  final _sectionOpen = <String>{};
  final _navOpen = <String>{};

  /// The seek bar stays open until a tap on the text. [_seek] is the spot it shows while open.
  var _seekOpen = false;
  double? _seek;
  double _seekFrom = 0;
  var _seekMarked = false;
  var _seekHeld = false;
  int? _seekSnap;
  var _seekBusy = false;
  ({double value, int? chapter})? _seekQueued;

  var _index = 0;
  var _page = 0;
  var _pageCount = 1;
  int? _firstOnPage;
  var _settling = false;
  var _loadGen = 0;
  var _ready = false;
  String? _error;
  AppThemeKind? _appliedTheme;

  var _chrome = false;
  Timer? _hideTimer;
  _Panel? _panel;
  /// The word in the lookup sheet. Null while the sheet is closed.
  String? _lookup;
  _Pick? _pick;
  var _selectReady = false;
  var _pickSearch = false;
  var _tocTab = _TocTab.contents;
  List<_BookImage>? _images;
  final _imageBytes = <String, Future<List<int>?>>{};
  var _busy = false;
  LibraryController? _library;

  /// The brightness bar's spot while the system decides the brightness.
  double? _systemLight;

  FlutterTts? _tts;
  var _ttsOn = false;
  var _ttsPlaying = false;
  var _ttsIndex = 0;
  var _speakGen = 0;

  /// Where the voice is inside the sentence being spoken, and where a pause left it.
  var _spokenBase = 0;
  var _spokenAt = 0;
  var _resumeAt = 0;
  var _speechOpen = false;
  var _voicesLoaded = false;
  List<SystemVoice> _voices = const [];
  SpeechControls? _media;

  final _searchField = TextEditingController();
  List<SearchHit> _hits = const [];
  var _searching = false;
  String? _searchedFor;
  var _found = false;
  List<ChapterText>? _bookText;
  Future<List<ChapterText>?>? _bookTextJob;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_open());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _library = LibraryScope.of(context);
    final next = LibraryScope.of(context).theme;
    if (_appliedTheme == next) return;
    final first = _appliedTheme == null;
    _appliedTheme = next;
    if (first || !_ready || _server == null || _controller == null) return;
    unawaited(_reloadKeepingPlace());
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _speakGen++;
    unawaited(_tts?.stop());
    final media = _media;
    if (media != null) speechMedia?.detach(media);
    _searchField.dispose();
    _server?.close();
    unawaited(setScreenBrightness(null));
    unawaited(keepScreenOn(false));
    final library = _library;
    if (library != null && library.readingNow == widget.path) library.setReadingNow(null);
    super.dispose();
  }

  Future<void> _open() async {
    await _store.load();
    if (!mounted) return;
    final library = LibraryScope.of(context);
    library.setReadingNow(widget.path);
    if (library.keepAwake) unawaited(keepScreenOn(true));
    if (_store.brightness != null) unawaited(setScreenBrightness(_store.brightness));
    try {
      final book = library.bookByPath(widget.path);
      final zipped = book?.zipped ?? widget.path.toLowerCase().endsWith('.epub');
      final exists = zipped ? File(widget.path).existsSync() : Directory(widget.path).existsSync();
      if (!exists) {
        _fail('book.missing_path');
        return;
      }
      final BookFiles files = zipped ? await openZipBook(widget.path) : DirectoryBookFiles(widget.path);
      final parsed = await parseBook(files);
      if (!mounted) return;
      if (!parsed.ok) {
        _fail(parsed.failure ?? 'book.no_chapters');
        return;
      }
      await library.openData(
        widget.path,
        title: parsed.title ?? p.basenameWithoutExtension(widget.path),
        legacyMarks: _store.legacyMarks(widget.path),
        legacyTags: _store.legacyTags(widget.path),
      );
      unawaited(_store.dropLegacy(widget.path));
      if (!mounted) return;
      final kind = _appliedTheme ?? library.theme;
      final colors = AppColors.of(kind);
      final server = BookServer(
        files: files,
        paint: colors.paint,
      );
      await server.start();
      if (!mounted) {
        await server.close();
        return;
      }
      var index = book?.chapterIndex ?? 0;
      int? sentence = book?.sentenceId;
      int? page = book?.page;
      if (index < 0 || index >= parsed.chapters.length) {
        index = 0;
        sentence = null;
        page = null;
      }
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(colors.paper);
      await controller.addJavaScriptChannel('ReaderMsg', onMessageReceived: _onJsMessage);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigation,
          onPageFinished: (url) {
            final rev = int.tryParse(Uri.tryParse(url)?.queryParameters['rev'] ?? '');
            if (rev == null) return;
            unawaited(_afterLoad(rev));
          },
        ),
      );
      if (!mounted) {
        await server.close();
        return;
      }
      _server = server;
      _chapters = parsed.chapters;
      _toc = parsed.toc;
      _spineIndex = {for (var i = 0; i < parsed.chapters.length; i++) parsed.chapters[i].path: i};
      _controller = controller;
      setState(() => _ready = true);
      _attachMedia();
      await _loadChapter(index, sentenceId: sentence, page: sentence == null ? page : null);
      unawaited(_ensureWeights());
    } catch (_) {
      _fail('book.damaged');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _ready = false;
    });
  }

  void _applyPaint(AppThemeKind kind) {
    final colors = AppColors.of(kind);
    _server?.paint = colors.paint;
    _controller?.setBackgroundColor(colors.paper);
  }

  Future<void> _reloadKeepingPlace() async {
    if (!_ready || _controller == null) return;
    final kind = _appliedTheme ?? LibraryScope.of(context).theme;
    _applyPaint(kind);
    final top = await _jsInt('reader.firstOnPage()');
    if (!mounted) return;
    await _loadChapter(_index, sentenceId: top < 0 ? null : top);
  }

  /// [fraction] lands on the sentence that far into the chapter's text.
  Future<void> _loadChapter(
    int index, {
    int? sentenceId,
    int? page,
    String? anchor,
    int? image,
    bool end = false,
    double? fraction,
  }) async {
    final server = _server;
    final controller = _controller;
    if (server == null || controller == null) return;
    if (index < 0 || index >= _chapters.length) return;
    final gen = ++_loadGen;
    _pick = null;
    _selectReady = false;
    _pickSearch = false;
    final bytes = await server.files.read(_chapters[index].path);
    if (!mounted || gen != _loadGen) return;
    if (bytes == null) {
      _fail('book.damaged');
      return;
    }
    final prepared = prepareChapter(utf8.decode(bytes, allowMalformed: true));
    final kind = _appliedTheme ?? LibraryScope.of(context).theme;
    final dressed = dressChapter(prepared.html, paint: server.paint, layout: _store.layout);
    server.setPrepared(_chapters[index].path, utf8.encode(dressed));
    _sentences = prepared.sentences;
    _headings[index] = prepared.headings;
    _index = index;
    _restoreFraction = null;
    if (fraction != null) {
      sentenceId = sentenceAtFraction(prepared.sentences, fraction);
      if (sentenceId == null) _restoreFraction = fraction;
    }
    _restoreSentence = sentenceId;
    _restorePage = page;
    _restoreAnchor = anchor;
    _restoreImage = image;
    _restoreEnd = end;
    _settling = true;
    _found = false;
    if (!mounted || gen != _loadGen) return;
    LibraryScope.of(context).rememberChapter(widget.path, index);
    final done = Completer<void>();
    _loadDone = done;
    _loadDoneGen = gen;
    setState(() {});
    await controller.loadRequest(
      Uri.parse(
        bookUrl(
          port: server.port,
          bookPath: _chapters[index].path,
          themeKey: kind.name,
          revision: gen,
        ),
      ),
    );
    if (!mounted || gen != _loadGen) return;
    await done.future.timeout(const Duration(seconds: 8), onTimeout: () {});
    if (!mounted || gen != _loadGen) return;
    if (_settling) {
      _settling = false;
      _savePosition();
    }
  }

  int? _restoreSentence;
  int? _restorePage;
  double? _restoreFraction;
  String? _restoreAnchor;
  int? _restoreImage;
  var _restoreEnd = false;
  Completer<void>? _loadDone;
  var _loadDoneGen = -1;

  Future<void> _afterLoad(int rev) async {
    if (rev != _loadGen) return;
    try {
      var landed = await _jsInt('window.reader ? reader.boot(false) : -1');
      if (!mounted || rev != _loadGen) return;
      if (_restoreEnd) {
        _restoreEnd = false;
        landed = await _jsInt('reader.setPage(Math.max(0, reader.pages() - 1))');
      } else if (_restoreAnchor != null) {
        final anchor = _restoreAnchor;
        _restoreAnchor = null;
        final at = await _jsInt('reader.goAnchor(${jsonEncode(anchor)})');
        if (at >= 0) landed = at;
      } else if (_restoreImage != null) {
        final image = _restoreImage;
        _restoreImage = null;
        final at = await _jsInt('reader.goImage($image)');
        if (at >= 0) landed = at;
      } else if (_restoreSentence != null) {
        final id = _restoreSentence;
        _restoreSentence = null;
        landed = await _jsInt('reader.goSentence($id)');
      } else if (_restorePage != null) {
        final page = _restorePage;
        _restorePage = null;
        landed = await _jsInt('reader.setPage($page)');
      } else if (_restoreFraction != null) {
        final fraction = _restoreFraction;
        _restoreFraction = null;
        landed = await _jsInt('reader.setPage(Math.floor($fraction * (reader.pages() - 1) + 0.5))');
      }
      if (!mounted || rev != _loadGen) return;
      if (landed >= 0) setState(() => _page = landed);
      await _js('reader.setSpeaking($_ttsOn)');
      await _paintMarks();
      await _refreshTempPage();
      if (rev == _loadGen) {
        _firstOnPage = await _firstVisible();
        _settling = false;
        _savePosition();
      }
    } finally {
      if (rev == _loadDoneGen && _loadDone != null && !_loadDone!.isCompleted) {
        _loadDone!.complete();
      }
    }
  }

  Future<void> _paintMarks() async {
    final ranges = [
      for (final mark in LibraryScope.of(context).marksFor(widget.path))
        if (mark.chapter == _index) [mark.start, mark.startOffset, mark.end, mark.endOffset ?? -1],
    ];
    await _js('reader.marks(${jsonEncode(ranges)})');
  }

  /// A new layout moves sentences to other pages. The bookmark follows its sentence.
  Future<void> _refreshTempPage() async {
    final mark = _temp;
    final sid = mark?.sentenceId;
    if (mark == null || sid == null || mark.chapter != _index) return;
    final page = await _jsInt('reader.pageOf($sid)');
    if (!mounted || page < 0 || !identical(_temp, mark)) return;
    setState(() => _temp = _TempMark(chapter: mark.chapter, page: page, sentenceId: sid));
  }

  bool get _markIsHere => _temp != null && _temp!.chapter == _index && _temp!.page == _page;

  /// A paused WebView must not stall speech in the background.
  static const _jsWait = Duration(seconds: 2);

  Future<int?> _firstVisible() async {
    final id = await _jsInt('reader.firstOnPage()');
    return id < 0 ? null : id;
  }

  void _savePosition() {
    if (!mounted || !_ready || _settling || _chapters.isEmpty) return;
    LibraryScope.of(context).rememberPosition(
      widget.path,
      chapter: _index,
      sentenceId: _firstOnPage,
      page: _page,
      progress: _progressNow(),
    );
  }

  double _progressNow() {
    if (_chapters.isEmpty) return 0;
    final book = LibraryScope.of(context).bookByPath(widget.path);
    final inChapter = chapterFraction(
      sentences: _sentences,
      firstSentence: _firstOnPage,
      page: _page,
      pageCount: _pageCount,
    );
    return bookProgress(
      weights: book?.weights,
      chapterCount: _chapters.length,
      chapter: _index,
      inChapter: inChapter,
      atEnd: _page >= _pageCount - 1 && _index >= _chapters.length - 1,
    );
  }

  Future<List<ChapterText>?> _loadBookText() {
    final ready = _bookText;
    if (ready != null) return Future.value(ready);
    return _bookTextJob ??= () async {
      final server = _server;
      if (server == null) return null;
      final sources = <String>[];
      for (final chapter in _chapters) {
        final bytes = await server.files.read(chapter.path);
        sources.add(bytes == null ? '' : utf8.decode(bytes, allowMalformed: true));
      }
      List<ChapterText> text;
      try {
        text = await Isolate.run(() => analyzeBook(sources));
      } catch (_) {
        text = analyzeBook(sources);
      }
      _bookText = text;
      return text;
    }();
  }

  /// The first open measures every chapter. Later opens reuse the saved numbers.
  Future<void> _ensureWeights() async {
    final library = LibraryScope.of(context);
    final weights = library.bookByPath(widget.path)?.weights;
    if (weights != null && weights.length == _chapters.length) return;
    final text = await _loadBookText();
    if (!mounted || text == null || text.length != _chapters.length) return;
    await library.setWeights(widget.path, [for (final chapter in text) chapter.weight]);
    _savePosition();
  }

  Future<void> _js(String source) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.runJavaScript(source).timeout(_jsWait);
    } catch (_) {}
  }

  Future<int> _jsInt(String source) async {
    final controller = _controller;
    if (controller == null) return -1;
    try {
      final raw = await controller.runJavaScriptReturningResult(source).timeout(_jsWait);
      return int.tryParse('$raw'.replaceAll('"', '')) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  void _onJsMessage(JavaScriptMessage message) {
    if (!mounted) return;
    final decoded = jsonDecode(message.message);
    if (decoded is! Map) return;
    switch (decoded['type']) {
      case 'page':
        final page = decoded['page'];
        final pages = decoded['pages'];
        final first = decoded['first'];
        if (page is int && pages is int) {
          setState(() {
            _page = page;
            _pageCount = pages < 1 ? 1 : pages;
            _firstOnPage = first is int && first >= 0 ? first : null;
          });
          _savePosition();
        }
      case 'link':
        final href = decoded['href'];
        if (href is String) unawaited(_followLink(href));
      case 'tap':
        if (_closeSeek()) return;
        final zone = decoded['zone'];
        if (zone is String) _onZone(zone);
      case 'swipe':
        final dir = decoded['dir'];
        if (dir is! String) return;
        final vertical = _store.layout.writing == WritingMode.vertical;
        unawaited(_turn((dir == 'left') != vertical ? 1 : -1));
      case 'speakAt':
        if (_closeSeek()) return;
        final sid = decoded['sid'];
        if (sid is int) unawaited(_speakFrom(sid));
      case 'lookup':
        final word = decoded['word'];
        if (word is! String || word.trim().isEmpty) return;
        _closeSeek();
        setState(() {
          _lookup = word.trim();
          _selectReady = false;
          _pick = null;
        });
        unawaited(_sayOnLookup(word.trim()));
      case 'select':
        final start = decoded['start'];
        final end = decoded['end'];
        final text = decoded['text'];
        if (start is List && end is List && start.length == 2 && end.length == 2 && text is String) {
          final values = [...start, ...end];
          if (values.any((value) => value is! int)) return;
          _closeSeek();
          setState(() {
            _pickSearch = false;
            _pick = _Pick(
              startSid: values[0] as int,
              startOffset: values[1] as int,
              endSid: values[2] as int,
              endOffset: values[3] as int,
              text: text.replaceAll(RegExp(r'\s+'), ' ').trim(),
            );
          });
        }
      case 'selectEnd':
        if (_pick == null) return;
        setState(() => _selectReady = true);
        _armHide();
      case 'corner':
        if (_pick == null) return;
        final dir = decoded['dir'];
        if (dir == 'next') unawaited(_turn(1));
        if (dir == 'prev') unawaited(_turn(-1));
    }
  }

  NavigationDecision _onNavigation(NavigationRequest request) {
    final choice = decideBookNavigation(
      requestUrl: request.url,
      port: _server?.port ?? 0,
      chapterPaths: [for (final chapter in _chapters) chapter.path],
    );
    if (!request.isMainFrame) {
      return choice.blocked ? NavigationDecision.prevent : NavigationDecision.navigate;
    }
    final index = choice.chapterIndex;
    if (index != null) {
      if (index != _index) unawaited(_jump(chapter: index));
      return NavigationDecision.prevent;
    }
    if (choice.blocked) return NavigationDecision.prevent;
    return NavigationDecision.navigate;
  }

  void _onZone(String zone) {
    // While speech is on, only swipes turn pages.
    if (zone == 'center' || _ttsOn) {
      _toggleChrome();
      return;
    }
    final vertical = _store.layout.writing == WritingMode.vertical;
    final forward = vertical ? zone == 'left' : zone == 'right';
    unawaited(_turn(forward ? 1 : -1));
  }

  void _toggleChrome() {
    _hideTimer?.cancel();
    setState(() => _chrome = !_chrome);
    if (_chrome) _armHide();
  }

  void _armHide() {
    _hideTimer?.cancel();
    if (_panel != null || _selectReady || _speechOpen || _seekOpen) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _chrome = false);
    });
  }

  void _openPanel(_Panel panel) {
    _hideTimer?.cancel();
    setState(() {
      _panel = panel;
      if (panel == _Panel.toc) {
        _tocOpen
          ..clear()
          ..add(_index);
        _navOpen.clear();
        final current = _currentTocKey();
        if (current != null) {
          final parts = current.split('.');
          for (var i = 1; i < parts.length; i++) {
            _navOpen.add(parts.sublist(0, i).join('.'));
          }
        }
      }
    });
    if (panel == _Panel.toc) unawaited(_ensureHeadings(_index));
    if (panel == _Panel.toc && _tocTab == _TocTab.images) unawaited(_ensureImages());
  }

  void _closePanel() {
    setState(() => _panel = null);
    if (_chrome) _armHide();
  }

  Future<void> _ensureHeadings(int index) async {
    if (_headings.containsKey(index)) return;
    final server = _server;
    if (server == null || index < 0 || index >= _chapters.length) return;
    final bytes = await server.files.read(_chapters[index].path);
    if (!mounted || bytes == null) return;
    final prepared = prepareChapter(utf8.decode(bytes, allowMalformed: true));
    _headings[index] = prepared.headings;
    setState(() {});
  }

  Future<void> _setLayout(ReaderLayout layout) async {
    await _store.setLayout(layout);
    if (!mounted) return;
    await _reloadKeepingPlace();
  }

  Future<void> _turn(int delta, {bool fromSpeech = false}) async {
    if (_busy) return;
    if (!fromSpeech && _ttsPlaying) await _pauseSpeech();
    if (!mounted) return;
    if (_found) {
      _found = false;
      unawaited(_js('reader.clearFound()'));
    }
    final next = _page + delta;
    if (next >= 0 && next < _pageCount) {
      await _js('reader.setPage($next)');
      return;
    }
    if (_pick != null) return;
    _busy = true;
    try {
      if (delta > 0 && _index < _chapters.length - 1) {
        await _loadChapter(_index + 1);
      } else if (delta < 0 && _index > 0) {
        await _loadChapter(_index - 1, end: true);
      }
    } finally {
      _busy = false;
    }
  }

  /// Leaves the temporary bookmark behind when it moves more than one page.
  /// With [leaveMark] false, as when going back to the bookmark, nothing is left.
  /// With [alwaysMark], any move off this page leaves one, as from the highlights list.
  Future<void> _jump({
    required int chapter,
    int? sentenceId,
    int? page,
    String? anchor,
    int? image,
    bool leaveMark = true,
    bool alwaysMark = false,
  }) async {
    if (_busy || chapter < 0 || chapter >= _chapters.length) return;
    final fromChapter = _index;
    final fromPage = _page;
    final fromCount = _pageCount;
    final top = await _jsInt('reader.firstOnPage()');
    if (!mounted) return;
    setState(() => _panel = null);
    if (_chrome) _armHide();
    void leave() {
      if (leaveMark) _markDeparture(fromChapter, fromPage, top < 0 ? null : top);
    }

    bool far(int target) => alwaysMark ? target != fromPage : (target - fromPage).abs() > 1;

    if (chapter == _index && anchor != null) {
      final target = await _jsInt('reader.pageOfAnchor(${jsonEncode(anchor)})');
      if (target < 0) return;
      if (far(target)) leave();
      await _js('reader.goAnchor(${jsonEncode(anchor)})');
      return;
    }
    if (chapter == _index && image != null) {
      final target = await _jsInt('reader.pageOfImage($image)');
      if (target < 0) return;
      if (far(target)) leave();
      await _js('reader.goImage($image)');
      return;
    }
    if (chapter == _index && sentenceId != null) {
      final target = await _jsInt('reader.pageOf($sentenceId)');
      if (target >= 0 && far(target)) leave();
      await _js('reader.goSentence($sentenceId)');
      return;
    }
    if (chapter == _index && page != null) {
      if (far(page)) leave();
      await _js('reader.setPage($page)');
      return;
    }
    _busy = true;
    try {
      await _loadChapter(
        chapter,
        sentenceId: sentenceId,
        page: sentenceId == null ? page : null,
        anchor: anchor,
        image: image,
      );
    } finally {
      _busy = false;
    }
    if (!mounted) return;
    final single = isSinglePageStep(
      fromChapter: fromChapter,
      fromPage: fromPage,
      fromPageCount: fromCount,
      toChapter: _index,
      toPage: _page,
      toPageCount: _pageCount,
    );
    if (!single || alwaysMark) leave();
  }

  /// Only one temporary bookmark. Later jumps keep the first one.
  void _markDeparture(int chapter, int page, int? sentenceId) {
    if (_temp != null) return;
    setState(() => _temp = _TempMark(chapter: chapter, page: page, sentenceId: sentenceId));
  }

  /// The top bar's bookmark button. It moves the one bookmark here, or takes it out when it is already here.
  Future<void> _markHere() async {
    if (_markIsHere) {
      setState(() => _temp = null);
      _armHide();
      return;
    }
    final top = await _firstVisible();
    if (!mounted) return;
    setState(() => _temp = _TempMark(chapter: _index, page: _page, sentenceId: top));
    _armHide();
  }

  /// The name starts as the selected text, then a highlight on this page, then the chapter's label.
  Future<void> _addTag() async {
    _hideTimer?.cancel();
    final pick = _pick;
    var name = pick?.text ?? '';
    var sentenceId = pick?.startSid;
    if (name.isEmpty) {
      final marks = LibraryScope.of(context).marksFor(widget.path);
      for (final mark in marks) {
        if (mark.chapter != _index) continue;
        final at = await _jsInt('reader.pageOf(${mark.start})');
        if (at == _page) {
          name = mark.text.replaceAll(RegExp(r'\s+'), ' ').trim();
          break;
        }
      }
    }
    sentenceId ??= await _firstVisible();
    if (!mounted) return;
    if (name.isEmpty && _index < _chapters.length) name = _chapters[_index].label;
    if (name.length > _tagNameMax) name = name.substring(0, _tagNameMax);
    final result = await _editTag(name, removable: false);
    if (!mounted) return;
    if (result != null && result.name.isNotEmpty) {
      LibraryScope.of(context).addTag(
        widget.path,
        BookTag(
          id: DateTime.now().millisecondsSinceEpoch,
          chapter: _index,
          name: result.name,
          sentenceId: sentenceId,
          page: _page,
        ),
      );
      if (pick != null) await _clearSelection();
    }
    if (mounted) setState(() {});
    if (_chrome) _armHide();
  }

  static const _tagNameMax = 80;

  Future<void> _changeTag(BookTag tag) async {
    final result = await _editTag(tag.name, removable: true);
    if (!mounted || result == null) return;
    final library = LibraryScope.of(context);
    if (result.remove) {
      library.updateTag(widget.path, tag.id, null);
    } else if (result.name.isNotEmpty) {
      library.updateTag(widget.path, tag.id, tag.renamed(result.name));
    }
    if (mounted) setState(() {});
  }

  /// Null when cancelled.
  Future<({String name, bool remove})?> _editTag(String initial, {required bool removable}) {
    final field = TextEditingController(text: initial)..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
    return showGeneralDialog<({String name, bool remove})>(
      context: context,
      barrierDismissible: true,
      barrierLabel: _t('common.close'),
      barrierColor: const Color(0x66000000),
      transitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) {
        final colors = colorsOf(context);
        final border = OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: BorderSide(color: colors.line),
        );
        void save() => Navigator.of(context).pop((name: field.text.trim(), remove: false));
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Material(
              color: colors.paper,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(controlRadius),
                side: BorderSide(color: colors.fill, width: 2),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(_t('tag.name'), style: TextStyle(color: colors.ink, fontSize: 14)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: field,
                      autofocus: true,
                      maxLength: _tagNameMax,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => save(),
                      cursorColor: colors.ink,
                      style: TextStyle(color: colors.ink, fontSize: 16),
                      decoration: InputDecoration(
                        isDense: true,
                        counterText: '',
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        border: border,
                        enabledBorder: border,
                        focusedBorder: border,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (removable)
                          StaticTextButton(
                            label: _t('tag.remove'),
                            onPressed: () => Navigator.of(context).pop((name: '', remove: true)),
                          ),
                        const Spacer(),
                        StaticTextButton(label: _t('common.cancel'), onPressed: () => Navigator.of(context).pop()),
                        const SizedBox(width: 8),
                        StaticTextButton(label: _t('common.save'), emphasize: true, onPressed: save),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ).whenComplete(() => WidgetsBinding.instance.addPostFrameCallback((_) => field.dispose()));
  }

  void _returnToMark() {
    final mark = _temp;
    if (mark == null) return;
    setState(() => _temp = null);
    unawaited(
      _jump(
        chapter: mark.chapter,
        sentenceId: mark.sentenceId,
        page: mark.sentenceId == null ? mark.page : null,
        leaveMark: false,
      ),
    );
  }

  void _openSeek() {
    _hideTimer?.cancel();
    if (!_seekOpen) {
      _seekFrom = _progressNow();
      _seekMarked = false;
    }
    setState(() {
      _seekOpen = true;
      _seek ??= _seekFrom;
    });
  }

  /// Returns whether the bar was open.
  bool _closeSeek() {
    if (!_seekOpen) return false;
    setState(() {
      _seekOpen = false;
      _seekHeld = false;
      _seekSnap = null;
      _seek = null;
    });
    if (_chrome) _armHide();
    return true;
  }

  /// Holding the percent: [delta] is the finger's move as a share of the bar's width.
  void _seekHold(double delta, double barWidth) {
    _seekPlace(_seekFrom + delta, barWidth, held: true);
  }

  /// A chapter start within a few pixels of the finger pulls the spot onto it.
  void _seekPlace(double raw, double barWidth, {bool held = false}) {
    final book = LibraryScope.of(context).bookByPath(widget.path);
    final starts = chapterStarts(weights: book?.weights, chapterCount: _chapters.length);
    final reach = barWidth <= 0 ? 0.0 : _snapPx / barWidth;
    var value = raw.clamp(0.0, 1.0);
    final snap = snapChapter(starts, value, reach);
    if (snap != null) value = starts[snap];
    setState(() {
      _seek = value;
      _seekSnap = snap;
      _seekHeld = held;
    });
    if (!_seekMarked && (value - _seekFrom).abs() >= 0.001) {
      _seekMarked = true;
      _markDeparture(_index, _page, _firstOnPage);
    }
    if (_seekMarked) _queueSeek(value, snap);
  }

  static const _snapPx = 10.0;

  void _seekRelease() {
    if (!_seekHeld) return;
    setState(() => _seekHeld = false);
  }

  /// Only the newest spot is shown. Spots passed while a chapter loads are dropped.
  Future<void> _queueSeek(double value, int? chapterStart) async {
    _seekQueued = (value: value, chapter: chapterStart);
    if (_seekBusy) return;
    _seekBusy = true;
    try {
      while (mounted && _seekQueued != null) {
        final next = _seekQueued!;
        _seekQueued = null;
        await _seekTo(next.value, chapterStart: next.chapter);
      }
    } finally {
      _seekBusy = false;
    }
  }

  /// With [chapterStart], opens that chapter's first page instead of reading [value].
  Future<void> _seekTo(double value, {int? chapterStart}) async {
    if (chapterStart != null) {
      if (_ttsPlaying) await _pauseSpeech();
      if (!mounted || _busy) return;
      if (chapterStart == _index) {
        await _js('reader.setPage(0)');
        return;
      }
      _busy = true;
      try {
        await _loadChapter(chapterStart);
      } finally {
        _busy = false;
      }
      return;
    }
    if (_ttsPlaying) await _pauseSpeech();
    if (!mounted || _busy) return;
    if (_found) {
      _found = false;
      unawaited(_js('reader.clearFound()'));
    }
    final book = LibraryScope.of(context).bookByPath(widget.path);
    final spot = locateProgress(weights: book?.weights, chapterCount: _chapters.length, progress: value);
    if (spot.chapter == _index) {
      final sid = sentenceAtFraction(_sentences, spot.inChapter);
      if (sid != null) {
        await _js('reader.goSentence($sid)');
      } else {
        await _js('reader.setPage(${(spot.inChapter * (_pageCount - 1)).round()})');
      }
      return;
    }
    _busy = true;
    try {
      await _loadChapter(spot.chapter, fraction: spot.inChapter);
    } finally {
      _busy = false;
    }
  }

  /// Note numbers and other links in the book. They win over the page-turn zones.
  Future<void> _followLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    final choice = decideBookNavigation(
      requestUrl: href,
      port: _server?.port ?? 0,
      chapterPaths: [for (final chapter in _chapters) chapter.path],
    );
    final chapter = choice.chapterIndex;
    if (chapter == null) return;
    if (_ttsPlaying) await _pauseSpeech();
    if (!mounted) return;
    final fragment = uri.fragment.isEmpty ? null : Uri.decodeComponent(uri.fragment);
    await _jump(chapter: chapter, anchor: fragment);
  }

  Future<void> _runSearch() async {
    final query = _searchField.text.trim();
    if (query.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();
    setState(() => _searching = true);
    final text = await _loadBookText();
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searchedFor = query;
      _hits = text == null ? const [] : searchBook(text, query, limit: _searchLimit);
    });
  }

  static const _searchLimit = 300;

  Future<void> _openHit(SearchHit hit) async {
    await _jump(chapter: hit.chapter, sentenceId: hit.sentenceId);
    if (!mounted || hit.chapter != _index) return;
    _found = true;
    await _js('reader.found(${hit.sentenceId})');
  }

  FlutterTts _ensureTts() {
    final ready = _tts;
    if (ready != null) return ready;
    final tts = FlutterTts();
    // Android 8 and later report each word. Older phones only report the start.
    tts.setProgressHandler((text, start, end, word) {
      _spokenAt = _spokenBase + start;
      _markWord(_spokenBase + start, _spokenBase + end);
    });
    return _tts = tts;
  }

  /// Paints the spoken word inside the sentence and turns the page when the word is on the next one.
  void _markWord(int start, int end) {
    if (!_ttsPlaying || _ttsIndex >= _sentences.length || end <= start) return;
    final id = _sentences[_ttsIndex].id;
    unawaited(_js('reader.word($id, $start, $end)'));
  }

  Future<void> _startSpeech() async {
    final tts = _ensureTts();
    await tts.awaitSpeakCompletion(true);
    await _applyVoice();
    if (!mounted) return;
    final top = await _jsInt('reader.firstOnPage()');
    if (!mounted) return;
    var start = 0;
    if (top >= 0) {
      final index = _sentences.indexWhere((sentence) => sentence.id == top);
      if (index >= 0) start = index;
    }
    final book = LibraryScope.of(context).bookByPath(widget.path);
    final saved = book?.speechSentence;
    if (book?.speechChapter == _index && saved != null && saved >= 0 && saved < _sentences.length) {
      final at = await _jsInt('reader.pageOf($saved)');
      if (!mounted) return;
      if (at == _page) start = saved;
    }
    _showMedia(playing: true);
    _resumeAt = 0;
    setState(() {
      _ttsOn = true;
      _ttsPlaying = true;
      _panel = null;
      _ttsIndex = start;
    });
    await _js('reader.setSpeaking(true)');
    unawaited(_runSpeech(start));
  }

  /// A tap on a sentence while speech is on reads that sentence at once.
  Future<void> _speakFrom(int sentenceId) async {
    if (!_ttsOn || _busy) return;
    var cursor = _sentences.indexWhere((sentence) => sentence.id == sentenceId);
    if (cursor < 0) return;
    while (cursor < _sentences.length && !_sentences[cursor].speak) {
      cursor++;
    }
    if (cursor >= _sentences.length) return;
    _speakGen++;
    await _tts?.stop();
    if (!mounted) return;
    _resumeAt = 0;
    _ttsIndex = cursor;
    _showMedia(playing: true);
    setState(() => _ttsPlaying = true);
    unawaited(_runSpeech(cursor));
  }

  /// [offset] starts the first sentence part way in, after a pause.
  Future<void> _runSpeech(int start, {int offset = 0}) async {
    final tts = _tts;
    if (tts == null) return;
    final gen = ++_speakGen;
    var cursor = start;
    var skip = offset;
    while (mounted && gen == _speakGen && _ttsPlaying) {
      while (cursor < _sentences.length && !_sentences[cursor].speak) {
        cursor++;
      }
      if (cursor >= _sentences.length) {
        if (_index >= _chapters.length - 1) {
          setState(() => _ttsPlaying = false);
          _showMedia(playing: false);
          await _js('reader.clearHighlight()');
          return;
        }
        await _loadChapter(_index + 1);
        if (!mounted || gen != _speakGen || !_ttsPlaying) return;
        cursor = 0;
        skip = 0;
        continue;
      }
      final sentence = _sentences[cursor];
      final target = await _jsInt('reader.speakPage(${sentence.id})');
      if (target >= 0 && target != _page) {
        await _js('reader.setPage($target)');
      }
      if (!mounted || gen != _speakGen || !_ttsPlaying) return;
      _ttsIndex = cursor;
      LibraryScope.of(context).rememberSpeech(widget.path, _index, sentence.id);
      await _js('reader.highlight(${sentence.id})');
      if (gen != _speakGen || !_ttsPlaying) return;
      final from = skip > 0 && skip < sentence.text.length ? skip : 0;
      skip = 0;
      final runs = sentence.runs.isEmpty ? [SpeechRun(0, sentence.text.length, 0)] : sentence.runs;
      for (final run in runs) {
        if (run.end <= from) continue;
        final start = run.start < from ? from : run.start;
        await _applyVoice(style: run.style);
        if (gen != _speakGen || !_ttsPlaying) return;
        final part = sentence.text.substring(start, run.end);
        _spokenBase = start;
        _spokenAt = start;
        if (part.trim().isNotEmpty) await tts.speak(part);
        if (gen != _speakGen || !_ttsPlaying) return;
      }
      cursor++;
    }
  }

  Future<void> _pauseSpeech() async {
    _ttsPlaying = false;
    _speakGen++;
    _resumeAt = _spokenAt;
    _showMedia(playing: false);
    await _tts?.stop();
    if (mounted) setState(() {});
  }

  /// Picks up at the word the pause cut off, when the voice reported words.
  Future<void> _resumeSpeech() async {
    if (!mounted) return;
    setState(() => _ttsPlaying = true);
    _showMedia(playing: true);
    final offset = _resumeAt;
    _resumeAt = 0;
    unawaited(_runSpeech(_ttsIndex, offset: offset));
  }

  void _attachMedia() {
    final media = _media ??= SpeechControls(
      play: () async {
        if (!_ttsOn) {
          await _startSpeech();
        } else if (!_ttsPlaying) {
          await _resumeSpeech();
        }
      },
      pause: _pauseSpeech,
      stop: _stopSpeech,
      next: () => _skipSentence(1),
      previous: () => _skipSentence(-1),
    );
    speechMedia?.attach(media);
  }

  void _showMedia({required bool playing}) {
    final handler = speechMedia;
    if (handler == null || !mounted) return;
    final book = LibraryScope.of(context).bookByPath(widget.path);
    handler.describe(
      title: book?.title ?? p.basename(widget.path),
      chapter: _index < _chapters.length ? _chapters[_index].label : null,
    );
    handler.show(playing: playing);
  }

  /// Previous or next sentence, across chapters. Keeps playing if it was playing.
  Future<void> _skipSentence(int delta) async {
    if (!_ttsOn || _busy) return;
    final playing = _ttsPlaying;
    _speakGen++;
    _resumeAt = 0;
    await _tts?.stop();
    if (!mounted) return;
    var cursor = _ttsIndex + delta;
    while (cursor >= 0 && cursor < _sentences.length && !_sentences[cursor].speak) {
      cursor += delta;
    }
    if (cursor < 0 || cursor >= _sentences.length) {
      final next = _index + (delta > 0 ? 1 : -1);
      if (next < 0 || next >= _chapters.length) {
        cursor = _ttsIndex;
      } else {
        _busy = true;
        try {
          await _loadChapter(next, end: delta < 0);
        } finally {
          _busy = false;
        }
        if (!mounted) return;
        cursor = delta > 0 ? 0 : _sentences.length - 1;
        while (cursor >= 0 && cursor < _sentences.length && !_sentences[cursor].speak) {
          cursor += delta > 0 ? 1 : -1;
        }
        if (cursor < 0 || cursor >= _sentences.length) cursor = 0;
      }
    }
    _ttsIndex = cursor;
    if (playing) {
      _ttsPlaying = true;
      unawaited(_runSpeech(cursor));
      return;
    }
    if (cursor >= _sentences.length) return;
    final sentence = _sentences[cursor];
    final target = await _jsInt('reader.speakPage(${sentence.id})');
    if (target >= 0 && target != _page) await _js('reader.setPage($target)');
    await _js('reader.highlight(${sentence.id})');
    if (mounted) LibraryScope.of(context).rememberSpeech(widget.path, _index, sentence.id);
  }

  Future<void> _stopSpeech() async {
    _ttsPlaying = false;
    _speakGen++;
    _resumeAt = 0;
    await _tts?.stop();
    speechMedia?.idle();
    await _js('reader.clearHighlight(); reader.setSpeaking(false)');
    if (!mounted) return;
    setState(() {
      _ttsOn = false;
      _speechOpen = false;
    });
  }

  /// Bold reads slower and a little deeper. Italic uses a second speaker and a little higher,
  /// so it still stands out when the phone has only one voice.
  Future<void> _applyVoice({int style = 0}) async {
    final tts = _tts;
    if (tts == null) return;
    final bold = style & speechBold != 0;
    final italic = style & speechItalic != 0;
    await tts.setSpeechRate(_store.paceRate * (bold ? 0.8 : 1));
    await tts.setPitch((bold ? 0.9 : 1) * (italic ? 1.15 : 1));
    if (!_voicesLoaded) await _loadVoices();
    final main = pickSystemVoice(_voices, _store.language);
    final picked = italic ? pickSecondVoice(_voices, main) ?? main : main;
    final locale = picked?.locale ?? preferredSpeechLocale(_store.language);
    await tts.setLanguage(locale);
    if (picked != null) {
      await tts.setVoice({'name': picked.name, 'locale': picked.locale});
    }
  }

  Future<void> _sayOnLookup(String word) async {
    final mode = LibraryScope.of(context).lookupSpeak;
    if (mode == LookupSpeak.never) return;
    if (mode == LookupSpeak.headphones && !await headphonesConnected()) return;
    if (!mounted || _lookup != word) return;
    await _sayWord(word);
  }

  /// One word in a British English system voice. Book speech pauses first, so play resumes there.
  Future<void> _sayWord(String word) async {
    if (_ttsPlaying) await _pauseSpeech();
    final tts = _ensureTts();
    if (!_voicesLoaded) await _loadVoices();
    if (!mounted) return;
    await tts.stop();
    await tts.setSpeechRate(0.45);
    await tts.setPitch(1);
    final picked = pickBritishVoice(_voices);
    await tts.setLanguage(picked?.locale ?? 'en-GB');
    if (picked != null) await tts.setVoice({'name': picked.name, 'locale': picked.locale});
    unawaited(tts.speak(word));
  }

  Future<void> _loadVoices() async {
    final tts = _ensureTts();
    try {
      final raw = await tts.getVoices;
      final voices = <SystemVoice>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          final name = item['name'];
          final locale = item['locale'];
          if (name is! String || locale is! String) continue;
          if (name.isEmpty || locale.isEmpty) continue;
          voices.add(SystemVoice(name: name, locale: locale));
        }
      }
      _voicesLoaded = true;
      if (mounted) setState(() => _voices = voices);
    } catch (_) {
      _voicesLoaded = true;
      if (mounted) setState(() => _voices = const []);
    }
  }

  Future<void> _copySelection() async {
    final text = _pick?.text ?? '';
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    await _clearSelection();
  }

  Future<void> _saveSelection() async {
    final pick = _pick;
    if (pick == null || pick.text.isEmpty) return;
    final library = LibraryScope.of(context);
    if (_marksUnderPick().isNotEmpty) return;
    library.addMark(
      widget.path,
      HighlightMark(
        chapter: _index,
        start: pick.startSid,
        end: pick.endSid,
        text: pick.text,
        startOffset: pick.startOffset,
        endOffset: pick.endOffset,
        created: DateTime.now(),
      ),
    );
    await _clearSelection();
    await _paintMarks();
  }

  /// Highlights that share a character with the selection. One passage is never highlighted twice.
  List<HighlightMark> _marksUnderPick() {
    final pick = _pick;
    if (pick == null) return const [];
    return marksOverlapping(
      LibraryScope.of(context).marksFor(widget.path),
      chapter: _index,
      startSid: pick.startSid,
      startOffset: pick.startOffset,
      endSid: pick.endSid,
      endOffset: pick.endOffset,
    );
  }

  Future<void> _removeSelectedMarks() async {
    final marks = _marksUnderPick();
    if (marks.isNotEmpty) LibraryScope.of(context).removeMarks(widget.path, marks);
    await _clearSelection();
    await _paintMarks();
  }

  Future<void> _removeMark(HighlightMark mark) async {
    LibraryScope.of(context).removeMarks(widget.path, [mark]);
    if (mark.chapter == _index) await _paintMarks();
  }

  Future<void> _findOnline(Uri Function(String text) address) async {
    final text = _pick?.text ?? '';
    if (text.isEmpty) return;
    await _clearSelection();
    try {
      await launchUrl(address(text), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _findInBook() async {
    final text = _pick?.text ?? '';
    if (text.isEmpty) return;
    await _clearSelection();
    if (!mounted) return;
    _searchField.text = text;
    _searchedFor = text;
    _openPanel(_Panel.search);
    await _runSearch();
  }

  Future<void> _clearSelection() async {
    _pick = null;
    _pickSearch = false;
    _selectReady = false;
    await _js('if (window.reader) reader.clearSelect()');
    if (mounted) setState(() {});
    if (_chrome) _armHide();
  }

  String _t(String key, [Map<String, String> args = const {}]) => tr(context, key, args);

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    final book = LibraryScope.of(context).bookByPath(widget.path);
    final title = book?.title ?? p.basename(widget.path);
    return PopScope(
      canPop: !_hasLayer,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeLayer();
      },
      child: _screen(colors, title),
    );
  }

  Widget _screen(AppColors colors, String title) {
    return Scaffold(
      backgroundColor: colors.paper,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                Column(
                  children: [
                    Expanded(child: _body(colors, title)),
                    if (_speechOpen)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 280),
                        child: SingleChildScrollView(child: _speechPanel(colors)),
                      ),
                    if (_ttsOn) _speechBar(colors),
                  ],
                ),
                if (_lookup != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: constraints.maxHeight / 2,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _lookup = null),
                    ),
                  ),
                if (_lookup != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: constraints.maxHeight / 2,
                    child: LookupSheet(
                      word: _lookup!,
                      onClose: () => setState(() => _lookup = null),
                      onSay: () => unawaited(_sayWord(_lookup!)),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Something the system back button closes before it leaves the book.
  bool get _hasLayer => _lookup != null || _panel != null || _speechOpen || _pick != null || _seekOpen;

  void _closeLayer() {
    if (_lookup != null) {
      setState(() => _lookup = null);
    } else if (_panel != null) {
      _closePanel();
    } else if (_speechOpen) {
      setState(() => _speechOpen = false);
    } else if (_pick != null) {
      unawaited(_clearSelection());
    } else {
      _closeSeek();
    }
  }

  Widget _body(AppColors colors, String title) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StaticTextButton(label: _t('reader.shelf'), onPressed: () => Navigator.of(context).maybePop()),
            const SizedBox(height: 16),
            Text(_t(_error!), style: const TextStyle(fontSize: 16, height: 1.4)),
          ],
        ),
      );
    }
    if (_controller == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(_t('book.opening'), style: const TextStyle(fontSize: 16)),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: _controller!)),
        if (_temp != null)
          Positioned(
            left: 0,
            top: _chrome ? _topBarHeight : 0,
            child: Semantics(
              button: true,
              label: _t('reader.temp_mark'),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _returnToMark,
                onLongPress: () => setState(() => _temp = null),
                child: SizedBox(
                  width: 48,
                  height: pageTopPx.toDouble(),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Icon(Icons.bookmark, size: pageTopPx - 2, color: colors.ink),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (_chrome) ...[
          Positioned(top: 0, left: 0, right: 0, child: _topBar(colors, title)),
          Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar(colors)),
        ],
        _progressLabel(colors),
        _pageLabel(colors),
        if (_seekOpen) Positioned(left: 16, right: 16, bottom: _chrome ? 84 : _seekBottom, child: _seekBar(colors)),
        if (_selectReady)
          Positioned(
            left: 8,
            right: 8,
            bottom: _chrome ? 84 : 36,
            child: Row(
              children: [
                for (final (index, button) in _pickButtons().indexed) ...[
                  if (index > 0) const SizedBox(width: 8),
                  Expanded(child: button),
                ],
              ],
            ),
          ),
        if (_panel == _Panel.layout) ...[
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _closePanel),
          ),
          Positioned.fill(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(widthFactor: 1, heightFactor: 0.5, child: _layoutPanel(colors)),
            ),
          ),
        ],
        if (_panel == _Panel.toc) ...[
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _closePanel),
          ),
          Positioned(left: 0, top: 0, bottom: 0, width: _tocWidth(context), child: _tocPanel(colors)),
        ],
        if (_panel == _Panel.brightness || _panel == _Panel.turn) ...[
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _closePanel),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: _chrome ? 84 : _seekBottom,
            child: _panel == _Panel.brightness ? _brightnessPanel(colors) : _turnPanel(colors),
          ),
        ],
        if (_panel == _Panel.search) Positioned.fill(child: _searchPanel(colors)),
      ],
    );
  }

  List<Widget> _pickButtons() {
    StaticTextButton button(String key, Future<void> Function() action) =>
        StaticTextButton(label: _t(key), expand: true, onPressed: () => unawaited(action()));
    if (_pickSearch) {
      return [
        button('reader.find_google', () => _findOnline(googleSearchUrl)),
        button('reader.find_wiki', () => _findOnline(wikiSearchUrl)),
        button('reader.find_book', _findInBook),
        button('common.back', () async => setState(() => _pickSearch = false)),
      ];
    }
    return [
      button('reader.copy', _copySelection),
      if (_marksUnderPick().isEmpty)
        button('reader.highlight', _saveSelection)
      else
        button('reader.unhighlight', _removeSelectedMarks),
      button('reader.find', () async => setState(() => _pickSearch = true)),
      button('common.close', _clearSelection),
    ];
  }

  static const _topBarHeight = 52.0;
  static const _seekBottom = 28.0;
  static const _seekInset = 16.0;
  static const _seekPad = 10.0;
  static const _seekThumb = 20.0;

  /// Whole-book percent at the bottom left, clear of the system home bar.
  /// A tap opens the seek bar. Holding it and sliding also moves through the book.
  Widget _progressLabel(AppColors colors) {
    final value = _seek ?? _progressNow();
    final width = MediaQuery.sizeOf(context).width - _seekInset * 2;
    return Positioned(
      left: 0,
      bottom: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _seekOpen ? _closeSeek() : _openSeek(),
        onLongPressStart: (_) => _openSeek(),
        onLongPressMoveUpdate: (details) => _seekHold(details.offsetFromOrigin.dx / (width <= 0 ? 1 : width), width),
        onLongPressEnd: (_) => _seekRelease(),
        onLongPressCancel: _seekRelease,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 24, 6),
          child: Text(
            '${(value * 100).floor()}%',
            style: TextStyle(color: colors.ink, fontSize: 14, fontWeight: _seekOpen ? FontWeight.bold : null),
          ),
        ),
      ),
    );
  }

  /// This chapter's page and page count, bottom centre.
  Widget _pageLabel(AppColors colors) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Text(
            '${_page + 1} / $_pageCount',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.ink, fontSize: 14),
          ),
        ),
      ),
    );
  }

  /// The seek bar's buttons: the book's first page, and the first page of the previous or next chapter.
  /// They leave the temporary bookmark as the first move on the bar does.
  Future<void> _seekChapter(int chapter) async {
    if (_busy || chapter < 0 || chapter >= _chapters.length) return;
    if (_ttsPlaying) await _pauseSpeech();
    if (!mounted) return;
    if (!_seekMarked) {
      _seekMarked = true;
      _markDeparture(_index, _page, _firstOnPage);
    }
    final book = LibraryScope.of(context).bookByPath(widget.path);
    final starts = chapterStarts(weights: book?.weights, chapterCount: _chapters.length);
    setState(() {
      _seek = starts[chapter];
      _seekFrom = starts[chapter];
      _seekSnap = null;
    });
    await _seekTo(starts[chapter], chapterStart: chapter);
  }

  Widget _seekButtons() {
    return Row(
      children: [
        Expanded(
          child: StaticTextButton(label: _t('reader.book_start'), expand: true, onPressed: () => unawaited(_seekChapter(0))),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: StaticTextButton(
            label: _t('reader.prev_chapter'),
            expand: true,
            onPressed: _index > 0 ? () => unawaited(_seekChapter(_index - 1)) : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: StaticTextButton(
            label: _t('reader.next_chapter'),
            expand: true,
            onPressed: _index < _chapters.length - 1 ? () => unawaited(_seekChapter(_index + 1)) : null,
          ),
        ),
      ],
    );
  }

  /// The chapter name rides above the thumb while a finger is on the bar.
  Widget _seekBar(AppColors colors) {
    final value = (_seek ?? 0).clamp(0.0, 1.0);
    final book = LibraryScope.of(context).bookByPath(widget.path);
    final chapter = _seekSnap ?? locateProgress(weights: book?.weights, chapterCount: _chapters.length, progress: value).chapter;
    final label = chapter >= 0 && chapter < _chapters.length ? _chapters[chapter].label : '';
    return LayoutBuilder(
      builder: (context, outer) {
        final track = outer.maxWidth - _seekPad * 2 - _seekThumb;
        double at(Offset local) => track <= 0 ? 0 : (local.dx - _seekPad - _seekThumb / 2) / track;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _seekButtons(),
            SizedBox(
              height: 40,
              child: _seekHeld && label.isNotEmpty
                  ? Align(
                      alignment: Alignment(value * 2 - 1, 1),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.paper,
                            border: Border.all(color: colors.fill, width: 2),
                            borderRadius: BorderRadius.circular(controlRadius),
                          ),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: outer.maxWidth * 0.8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: colors.ink, fontSize: 14, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => _seekPlace(at(details.localPosition), track, held: true),
              onTapUp: (_) => _seekRelease(),
              onTapCancel: _seekRelease,
              onHorizontalDragStart: (details) => _seekPlace(at(details.localPosition), track, held: true),
              onHorizontalDragUpdate: (details) => _seekPlace(at(details.localPosition), track, held: true),
              onHorizontalDragEnd: (_) => _seekRelease(),
              onHorizontalDragCancel: _seekRelease,
              child: _seekTrack(colors, value),
            ),
          ],
        );
      },
    );
  }

  Widget _seekTrack(AppColors colors, double value) {
    return DecoratedBox(
      decoration: _barDecoration(colors, edge: Border.all(color: colors.fill, width: 2), rounded: true),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _seekPad, vertical: 14),
        child: SizedBox(
          height: _seekThumb,
          child: LayoutBuilder(
            builder: (context, constraints) {
              const thumb = _seekThumb;
              final left = (constraints.maxWidth - thumb) * value;
              return Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: thumb / 2 - 2,
                    height: 4,
                    child: ColoredBox(color: colors.line),
                  ),
                  Positioned(
                    left: 0,
                    width: left + thumb / 2,
                    top: thumb / 2 - 2,
                    height: 4,
                    child: ColoredBox(color: colors.fill),
                  ),
                  Positioned(
                    left: left,
                    top: 0,
                    width: thumb,
                    height: thumb,
                    child: DecoratedBox(decoration: BoxDecoration(color: colors.fill, shape: BoxShape.circle)),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Light and dark get a see-through paper. The e-ink themes stay solid. Every theme gets a colored edge.
  BoxDecoration _barDecoration(AppColors colors, {required Border edge, bool rounded = false}) {
    final eink = colors.kind == AppThemeKind.einkWhite || colors.kind == AppThemeKind.einkBlack;
    return BoxDecoration(
      color: eink ? colors.paper : colors.paper.withAlpha(0xE0),
      border: edge,
      borderRadius: rounded ? BorderRadius.circular(controlRadius) : null,
    );
  }

  Border _edge(AppColors colors, {required bool top}) {
    final side = BorderSide(color: colors.fill, width: 2);
    return top ? Border(bottom: side) : Border(top: side);
  }

  double _tocWidth(BuildContext context) {
    final screen = MediaQuery.sizeOf(context).width;
    final width = screen * 0.86;
    return width > 420 ? 420 : width;
  }

  Widget _topBar(AppColors colors, String title) {
    return DecoratedBox(
      decoration: _barDecoration(colors, edge: _edge(colors, top: true)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          children: [
            StaticTextButton(label: _t('reader.shelf'), onPressed: () => Navigator.of(context).maybePop()),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 8),
            StaticTextButton(label: _t('reader.search'), onPressed: () => _openPanel(_Panel.search)),
            const SizedBox(width: 8),
            StaticTextButton(label: _t('reader.add_tag'), onPressed: () => unawaited(_addTag())),
            const SizedBox(width: 8),
            StaticTextButton(
              label: _t(_markIsHere ? 'reader.unbookmark' : 'reader.bookmark'),
              onPressed: () => unawaited(_markHere()),
            ),
          ],
        ),
      ),
    );
  }

  /// The bottom padding leaves room for the percent, drawn on top of this bar.
  Widget _bottomBar(AppColors colors) {
    return DecoratedBox(
      decoration: _barDecoration(colors, edge: _edge(colors, top: false)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 28),
        child: Row(
          children: [
            Expanded(child: StaticTextButton(label: _t('reader.toc'), expand: true, onPressed: () => _openPanel(_Panel.toc))),
            const SizedBox(width: 8),
            Expanded(child: StaticTextButton(label: _t('reader.layout'), expand: true, onPressed: () => _openPanel(_Panel.layout))),
            const SizedBox(width: 8),
            _BarIconButton(
              icon: Icons.brightness_6_outlined,
              label: _t('reader.brightness'),
              selected: _panel == _Panel.brightness,
              onPressed: () => _panel == _Panel.brightness ? _closePanel() : _openBrightness(),
            ),
            const SizedBox(width: 8),
            _BarIconButton(
              icon: Icons.screen_rotation_outlined,
              label: _t('reader.turn_screen'),
              selected: _panel == _Panel.turn,
              onPressed: () => _panel == _Panel.turn ? _closePanel() : _openPanel(_Panel.turn),
            ),
            const SizedBox(width: 8),
            Expanded(child: StaticTextButton(label: _t('reader.speech'), expand: true, onPressed: _ttsOn ? null : () => unawaited(_startSpeech()))),
          ],
        ),
      ),
    );
  }

  Future<void> _openBrightness() async {
    _openPanel(_Panel.brightness);
    if (_store.brightness != null) return;
    final light = await systemBrightness();
    if (mounted) setState(() => _systemLight = light);
  }

  /// Moves the brightness at once. It is saved when the finger lifts.
  void _lightMove(double value) {
    final light = value.clamp(0.0, 1.0);
    setState(() => _store.brightness = light);
    unawaited(setScreenBrightness(light));
  }

  void _lightDone() {
    final light = _store.brightness;
    if (light != null) unawaited(_store.setBrightness(light));
  }

  void _lightSystem() {
    unawaited(_store.setBrightness(null));
    unawaited(setScreenBrightness(null));
    setState(() {});
    unawaited(systemBrightness().then((light) {
      if (mounted) setState(() => _systemLight = light);
    }));
  }

  /// A bar above the bottom bar. Dragging it sets the screen brightness while reading.
  Widget _brightnessPanel(AppColors colors) {
    final own = _store.brightness;
    final value = own ?? _systemLight ?? 0.5;
    return DecoratedBox(
      decoration: _barDecoration(colors, edge: Border.all(color: colors.fill, width: 2), rounded: true),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.brightness_6_outlined, size: 20, color: colors.ink),
                const SizedBox(width: 8),
                Text(own == null ? _t('reader.brightness_system') : '${(own * 100).round()}%', style: TextStyle(color: colors.ink, fontSize: 14)),
                const Spacer(),
                StaticTextButton(label: _t('reader.brightness_system'), selected: own == null, onPressed: _lightSystem),
              ],
            ),
            LayoutBuilder(
              builder: (context, outer) {
                final track = outer.maxWidth - _seekPad * 2 - _seekThumb;
                double at(Offset local) => track <= 0 ? 0 : (local.dx - _seekPad - _seekThumb / 2) / track;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => _lightMove(at(details.localPosition)),
                  onTapUp: (_) => _lightDone(),
                  onHorizontalDragStart: (details) => _lightMove(at(details.localPosition)),
                  onHorizontalDragUpdate: (details) => _lightMove(at(details.localPosition)),
                  onHorizontalDragEnd: (_) => _lightDone(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: _seekPad, vertical: 14),
                    child: _lightTrack(colors, value),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _lightTrack(AppColors colors, double value) {
    return SizedBox(
      height: _seekThumb,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const thumb = _seekThumb;
          final left = (constraints.maxWidth - thumb) * value.clamp(0.0, 1.0);
          return Stack(
            children: [
              Positioned(left: 0, right: 0, top: thumb / 2 - 2, height: 4, child: ColoredBox(color: colors.line)),
              Positioned(left: 0, width: left + thumb / 2, top: thumb / 2 - 2, height: 4, child: ColoredBox(color: colors.fill)),
              Positioned(
                left: left,
                top: 0,
                width: thumb,
                height: thumb,
                child: DecoratedBox(decoration: BoxDecoration(color: colors.fill, shape: BoxShape.circle)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Fixes the screen's direction for the whole app, or leaves it to the phone.
  Widget _turnPanel(AppColors colors) {
    final library = LibraryScope.of(context);
    final turn = library.screenTurn;
    return DecoratedBox(
      decoration: _barDecoration(colors, edge: Border.all(color: colors.fill, width: 2), rounded: true),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: _options(_t('reader.turn_screen'), [
          for (final (value, key) in const [
            (ScreenTurn.auto, 'turn.auto'),
            (ScreenTurn.portrait, 'turn.portrait'),
            (ScreenTurn.landscape, 'turn.landscape'),
            (ScreenTurn.landscapeFlipped, 'turn.landscape_flipped'),
          ])
            _choice(_t(key), turn == value, () => library.setScreenTurn(value)),
        ]),
      ),
    );
  }

  /// The bottom half only. A tap on the uncovered half closes it.
  Widget _layoutPanel(AppColors colors) {
    final layout = _store.layout;
    final theme = LibraryScope.of(context).theme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.paper,
        border: Border(top: BorderSide(color: colors.fill, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              children: [
                _options(_t('layout.margin'), [
                  _choice(_t('layout.narrow'), layout.margin == MarginStep.narrow, () => _setLayout(layout.copyWith(margin: MarginStep.narrow))),
                  _choice(_t('layout.normal'), layout.margin == MarginStep.normal, () => _setLayout(layout.copyWith(margin: MarginStep.normal))),
                  _choice(_t('layout.wide'), layout.margin == MarginStep.wide, () => _setLayout(layout.copyWith(margin: MarginStep.wide))),
                ]),
                _options(_t('layout.margin_v'), [
                  _choice(_t('layout.narrow'), layout.marginV == MarginStep.narrow, () => _setLayout(layout.copyWith(marginV: MarginStep.narrow))),
                  _choice(_t('layout.normal'), layout.marginV == MarginStep.normal, () => _setLayout(layout.copyWith(marginV: MarginStep.normal))),
                  _choice(_t('layout.wide'), layout.marginV == MarginStep.wide, () => _setLayout(layout.copyWith(marginV: MarginStep.wide))),
                ]),
                _options(_t('layout.writing'), [
                  _choice(_t('layout.horizontal'), layout.writing == WritingMode.horizontal, () => _setLayout(layout.copyWith(writing: WritingMode.horizontal))),
                  _choice(_t('layout.vertical'), layout.writing == WritingMode.vertical, () => _setLayout(layout.copyWith(writing: WritingMode.vertical))),
                ]),
                _options(_t('layout.font'), [
                  _choice(_t('layout.sans'), layout.font == FontFace.sans, () => _setLayout(layout.copyWith(font: FontFace.sans))),
                  _choice(_t('layout.serif'), layout.font == FontFace.serif, () => _setLayout(layout.copyWith(font: FontFace.serif))),
                ]),
                _options(_t('layout.size'), [
                  _choice(_t('layout.small'), layout.fontStep == FontStep.small, () => _setLayout(layout.copyWith(fontStep: FontStep.small))),
                  _choice(_t('layout.smaller'), layout.fontStep == FontStep.smaller, () => _setLayout(layout.copyWith(fontStep: FontStep.smaller))),
                  _choice(_t('layout.normal'), layout.fontStep == FontStep.normal, () => _setLayout(layout.copyWith(fontStep: FontStep.normal))),
                  _choice(_t('layout.larger'), layout.fontStep == FontStep.larger, () => _setLayout(layout.copyWith(fontStep: FontStep.larger))),
                  _choice(_t('layout.large'), layout.fontStep == FontStep.large, () => _setLayout(layout.copyWith(fontStep: FontStep.large))),
                ]),
                _options(_t('layout.line'), [
                  _choice(_t('layout.tight'), layout.line == LineStep.tight, () => _setLayout(layout.copyWith(line: LineStep.tight))),
                  _choice(_t('layout.normal'), layout.line == LineStep.normal, () => _setLayout(layout.copyWith(line: LineStep.normal))),
                  _choice(_t('layout.loose'), layout.line == LineStep.loose, () => _setLayout(layout.copyWith(line: LineStep.loose))),
                ]),
                _options(_t('layout.theme'), [
                  _choice(_t('settings.theme_white'), theme == AppThemeKind.einkWhite, () => LibraryScope.of(context).setTheme(AppThemeKind.einkWhite)),
                  _choice(_t('settings.theme_black'), theme == AppThemeKind.einkBlack, () => LibraryScope.of(context).setTheme(AppThemeKind.einkBlack)),
                  _choice(_t('settings.theme_light'), theme == AppThemeKind.light, () => LibraryScope.of(context).setTheme(AppThemeKind.light)),
                  _choice(_t('settings.theme_dark'), theme == AppThemeKind.dark, () => LibraryScope.of(context).setTheme(AppThemeKind.dark)),
                ]),
                _options(_t('layout.turn'), [
                  _choice(_t('layout.page'), layout.turn == TurnMode.page, () => _setLayout(layout.copyWith(turn: TurnMode.page))),
                  _choice(_t('layout.scroll'), layout.turn == TurnMode.scroll, () => _setLayout(layout.copyWith(turn: TurnMode.scroll))),
                ]),
                if (MediaQuery.sizeOf(context).width > twoColumnMinWidth)
                  _options(_t('layout.columns'), [
                    _choice(_t('layout.one_column'), layout.columns == ColumnMode.single, () => _setLayout(layout.copyWith(columns: ColumnMode.single))),
                    _choice(_t('layout.two_columns'), layout.columns == ColumnMode.double, () => _setLayout(layout.copyWith(columns: ColumnMode.double))),
                  ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tocPanel(AppColors colors) {
    return ColoredBox(
      color: colors.paper,
      child: DecoratedBox(
        decoration: BoxDecoration(border: Border(right: BorderSide(color: colors.line))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    StaticTextButton(label: _t('common.close'), onPressed: _closePanel),
                    const SizedBox(width: 12),
                    for (final (tab, key) in const [
                      (_TocTab.contents, 'reader.toc'),
                      (_TocTab.marks, 'reader.marks'),
                      (_TocTab.tags, 'reader.tags'),
                      (_TocTab.images, 'reader.images'),
                    ]) ...[
                      StaticTextButton(label: _t(key), selected: _tocTab == tab, onPressed: () => _showTocTab(tab)),
                      const SizedBox(width: 6),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(child: _tocTabBody(colors)),
          ],
        ),
      ),
    );
  }

  /// The entry for the chapter being read: the last one that starts at or before it in the spine.
  String? _currentTocKey() {
    String? best;
    var bestIndex = -1;
    void visit(List<TocEntry> entries, String prefix) {
      for (var i = 0; i < entries.length; i++) {
        final key = prefix.isEmpty ? '$i' : '$prefix.$i';
        final spine = _spineIndex[entries[i].path];
        if (spine != null && spine <= _index && spine > bestIndex) {
          bestIndex = spine;
          best = key;
        }
        visit(entries[i].children, key);
      }
    }

    visit(_toc, '');
    return best;
  }

  Widget _navNode(TocEntry entry, String key, String? current) {
    final open = _navOpen.contains(key);
    final chapter = _spineIndex[entry.path];
    return Padding(
      padding: EdgeInsets.only(left: key.contains('.') ? 16 : 0, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (entry.children.isNotEmpty) ...[
                StaticTextButton(
                  label: open ? _t('reader.collapse') : _t('reader.expand'),
                  onPressed: () => setState(() => open ? _navOpen.remove(key) : _navOpen.add(key)),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: StaticTextButton(
                  label: entry.label,
                  expand: true,
                  selected: key == current,
                  onPressed: chapter == null ? null : () => unawaited(_jump(chapter: chapter, anchor: entry.fragment)),
                ),
              ),
            ],
          ),
          if (open) ...[
            const SizedBox(height: 8),
            for (var i = 0; i < entry.children.length; i++) _navNode(entry.children[i], '$key.$i', current),
          ],
        ],
      ),
    );
  }

  List<Widget> _tocChapter(int index) {
    final headings = _headings[index] ?? const <ChapterHeading>[];
    final open = _tocOpen.contains(index);
    final widgets = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            if (headings.isNotEmpty) ...[
              StaticTextButton(
                label: open ? _t('reader.collapse') : _t('reader.expand'),
                onPressed: () {
                  setState(() {
                    if (open) {
                      _tocOpen.remove(index);
                    } else {
                      _tocOpen.add(index);
                    }
                  });
                  if (!open) unawaited(_ensureHeadings(index));
                },
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: StaticTextButton(
                label: _chapters[index].label,
                expand: true,
                selected: index == _index,
                onPressed: () => unawaited(_jump(chapter: index)),
              ),
            ),
          ],
        ),
      ),
    ];
    if (!open) return widgets;
    for (final node in _tocTree(headings)) {
      widgets.add(_tocNode(index, node, 16));
    }
    return widgets;
  }

  Widget _tocNode(int chapter, _TocNode node, double indent) {
    final key = '$chapter:${node.heading.sentenceId}';
    final open = _sectionOpen.contains(key);
    return Padding(
      padding: EdgeInsets.only(left: indent, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (node.children.isNotEmpty) ...[
                StaticTextButton(
                  label: open ? _t('reader.collapse') : _t('reader.expand'),
                  onPressed: () {
                    setState(() {
                      if (open) {
                        _sectionOpen.remove(key);
                      } else {
                        _sectionOpen.add(key);
                      }
                    });
                  },
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: StaticTextButton(
                  label: node.heading.text,
                  expand: true,
                  onPressed: () => unawaited(_jump(chapter: chapter, sentenceId: node.heading.sentenceId)),
                ),
              ),
            ],
          ),
          if (open)
            for (final child in node.children) _tocNode(chapter, child, 16),
        ],
      ),
    );
  }

  void _showTocTab(_TocTab tab) {
    setState(() => _tocTab = tab);
    if (tab == _TocTab.images) unawaited(_ensureImages());
  }

  Widget _tocTabBody(AppColors colors) {
    Widget empty(String key) => Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_t(key), style: const TextStyle(fontSize: 16, height: 1.4)),
        );
    final library = LibraryScope.of(context);
    switch (_tocTab) {
      case _TocTab.contents:
        return ListView(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: _toc.isNotEmpty
              ? [
                  for (var i = 0; i < _toc.length; i++) _navNode(_toc[i], '$i', _currentTocKey()),
                ]
              : [
                  for (var index = 0; index < _chapters.length; index++) ..._tocChapter(index),
                ],
        );
      case _TocTab.marks:
        // Newest first. Highlights saved before times were kept go last.
        final marks = [...library.marksFor(widget.path)]
          ..sort((a, b) => (b.created ?? DateTime(0)).compareTo(a.created ?? DateTime(0)));
        if (marks.isEmpty) return empty('reader.no_marks');
        return ListView(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: [
            for (final mark in marks)
              _placeTile(
                colors,
                chapter: mark.chapter,
                text: mark.text,
                time: mark.created,
                onTap: () => unawaited(_jump(chapter: mark.chapter, sentenceId: mark.start, alwaysMark: true)),
                onDelete: () => unawaited(_removeMark(mark)),
              ),
          ],
        );
      case _TocTab.tags:
        final tags = library.tagsFor(widget.path).reversed.toList();
        if (tags.isEmpty) return empty('reader.no_tags');
        return ListView(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: [
            for (final tag in tags)
              _placeTile(
                colors,
                chapter: tag.chapter,
                text: tag.name,
                time: DateTime.fromMillisecondsSinceEpoch(tag.id),
                onTap: () => unawaited(
                  _jump(
                    chapter: tag.chapter,
                    sentenceId: tag.sentenceId,
                    page: tag.sentenceId == null ? tag.page : null,
                    alwaysMark: true,
                  ),
                ),
                onLongPress: () => unawaited(_changeTag(tag)),
              ),
          ],
        );
      case _TocTab.images:
        final images = _images;
        if (images == null) return empty('reader.images_loading');
        if (images.isEmpty) return empty('reader.no_images');
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.7,
          ),
          itemCount: images.length,
          itemBuilder: (context, index) => _imageTile(colors, images[index]),
        );
    }
  }

  /// Every distinct image in the book, at the first place it appears.
  Future<void> _ensureImages() async {
    if (_images != null) return;
    final text = await _loadBookText();
    if (!mounted || text == null) return;
    final seen = <String>{};
    final images = <_BookImage>[];
    for (var chapter = 0; chapter < text.length && chapter < _chapters.length; chapter++) {
      final base = parentBookPath(_chapters[chapter].path);
      final sources = text[chapter].imageSources;
      for (var index = 0; index < sources.length; index++) {
        final src = sources[index];
        if (src == null) continue;
        final path = resolveBookHref(base, src);
        if (path == null || !seen.add(path)) continue;
        images.add(_BookImage(chapter: chapter, index: index, path: path));
      }
    }
    setState(() => _images = images);
  }

  Widget _imageTile(AppColors colors, _BookImage image) {
    final label = _chapters[image.chapter].label;
    final bytes = _imageBytes[image.path] ??= _server?.files.read(image.path) ?? Future.value(null);
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_jump(chapter: image.chapter, image: image.index, alwaysMark: true)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border.all(color: colors.line)),
                child: FutureBuilder<List<int>?>(
                  future: bytes,
                  builder: (context, snapshot) {
                    final data = snapshot.data;
                    if (data == null || data.isEmpty) return const SizedBox.expand();
                    return Image.memory(
                      Uint8List.fromList(data),
                      fit: BoxFit.contain,
                      cacheWidth: 240,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stack) => Center(
                        child: Text(p.basename(image.path), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: colors.muted, fontSize: 11)),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: colors.muted, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _placeTile(
    AppColors colors, {
    required int chapter,
    required String text,
    required VoidCallback onTap,
    DateTime? time,
    VoidCallback? onLongPress,
    VoidCallback? onDelete,
  }) {
    final chapterLabel = chapter >= 0 && chapter < _chapters.length ? _chapters[chapter].label : '';
    final when = formatReadTime(time);
    final label = [if (when != null) when, if (chapterLabel.isNotEmpty) chapterLabel].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onLongPress: onLongPress,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(controlRadius),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (label.isNotEmpty)
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colors.muted, fontSize: 12),
                          ),
                        if (label.isNotEmpty) const SizedBox(height: 4),
                        Text(
                          text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.ink, fontSize: 15, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  if (onDelete != null) ...[
                    const SizedBox(width: 8),
                    StaticTextButton(label: _t('tag.remove'), onPressed: onDelete),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchPanel(AppColors colors) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(controlRadius),
      borderSide: BorderSide(color: colors.line),
    );
    final String? status;
    if (_searching) {
      status = _t('search.busy');
    } else if (_searchedFor == null) {
      status = null;
    } else if (_hits.isEmpty) {
      status = _t('search.none');
    } else if (_hits.length >= _searchLimit) {
      status = _t('search.limit', {'n': '$_searchLimit'});
    } else {
      status = _t('search.count', {'n': '${_hits.length}'});
    }
    return ColoredBox(
      color: colors.paper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                StaticTextButton(label: _t('common.close'), onPressed: _closePanel),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchField,
                    autofocus: _searchedFor == null,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => unawaited(_runSearch()),
                    cursorColor: colors.ink,
                    style: TextStyle(color: colors.ink, fontSize: 16),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: _t('search.hint'),
                      hintStyle: TextStyle(color: colors.muted),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      border: border,
                      enabledBorder: border,
                      focusedBorder: border,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                StaticTextButton(
                  label: _t('reader.search'),
                  onPressed: _searching ? null : () => unawaited(_runSearch()),
                ),
              ],
            ),
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(status, style: TextStyle(color: colors.ink, fontSize: 14)),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              itemCount: _hits.length,
              itemBuilder: (context, index) => _hitTile(colors, _hits[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hitTile(AppColors colors, SearchHit hit) {
    final query = (_searchedFor ?? '').toLowerCase();
    final snippet = hit.snippet;
    final at = query.isEmpty ? -1 : snippet.toLowerCase().indexOf(query);
    final base = TextStyle(color: colors.ink, fontSize: 15, height: 1.4);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(_openHit(hit)),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(controlRadius),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _chapters[hit.chapter].label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text.rich(
                    at < 0
                        ? TextSpan(text: snippet)
                        : TextSpan(
                            children: [
                              TextSpan(text: snippet.substring(0, at)),
                              TextSpan(
                                text: snippet.substring(at, at + query.length),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  decoration: TextDecoration.underline,
                                  decorationColor: colors.ink,
                                ),
                              ),
                              TextSpan(text: snippet.substring(at + query.length)),
                            ],
                          ),
                    style: base,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _speechBar(AppColors colors) {
    return ColoredBox(
      color: colors.paper,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          children: [
            _SmallIconButton(
              icon: Icons.skip_previous,
              label: _t('reader.prev_sentence'),
              onPressed: () => unawaited(_skipSentence(-1)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _BigButton(
                label: _ttsPlaying ? _t('reader.pause') : _t('reader.play'),
                onPressed: () => unawaited(_ttsPlaying ? _pauseSpeech() : _resumeSpeech()),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _BigButton(label: _t('reader.stop'), onPressed: () => unawaited(_stopSpeech())),
            ),
            const SizedBox(width: 8),
            _SmallIconButton(
              icon: Icons.skip_next,
              label: _t('reader.next_sentence'),
              onPressed: () => unawaited(_skipSentence(1)),
            ),
            const SizedBox(width: 8),
            StaticTextButton(
              label: '⋯',
              onPressed: () {
                setState(() => _speechOpen = !_speechOpen);
                if (_speechOpen && !_voicesLoaded) unawaited(_loadVoices());
                _armHide();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _speechPanel(AppColors colors) {
    return ColoredBox(
      color: colors.paper,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _options(_t('speech.source'), [
              _choice(_t('speech.system'), _store.engine == SpeechEngine.system, () {}),
              StaticTextButton(label: _t('speech.cloud_off'), onPressed: null),
            ]),
            _options(_t('speech.language'), [
              _choice(_t('speech.yue'), _store.language == SpeechLanguage.cantonese, () => _setLanguage(SpeechLanguage.cantonese)),
              _choice(_t('speech.cmn'), _store.language == SpeechLanguage.mandarin, () => _setLanguage(SpeechLanguage.mandarin)),
              _choice(_t('speech.en'), _store.language == SpeechLanguage.english, () => _setLanguage(SpeechLanguage.english)),
            ]),
            if (_voicesLoaded && pickSystemVoice(_voices, _store.language) == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(_t('speech.no_voice'), style: const TextStyle(fontSize: 14)),
              ),
            _options(_t('speech.pace'), [
              _choice(_t('speech.slow'), _store.pace == SpeechPace.slow, () => _setPace(SpeechPace.slow)),
              _choice(_t('speech.slower'), _store.pace == SpeechPace.slower, () => _setPace(SpeechPace.slower)),
              _choice(_t('layout.normal'), _store.pace == SpeechPace.normal, () => _setPace(SpeechPace.normal)),
              _choice(_t('speech.faster'), _store.pace == SpeechPace.faster, () => _setPace(SpeechPace.faster)),
              _choice(_t('speech.fast'), _store.pace == SpeechPace.fast, () => _setPace(SpeechPace.fast)),
            ]),
          ],
        ),
      ),
    );
  }

  Future<void> _setPace(SpeechPace pace) async {
    await _store.setPace(pace);
    await _applyVoice();
    if (mounted) setState(() {});
  }

  Future<void> _setLanguage(SpeechLanguage language) async {
    await _store.setLanguage(language);
    await _applyVoice();
    if (_ttsPlaying) {
      _speakGen++;
      await _tts?.stop();
      unawaited(_runSpeech(_ttsIndex));
    }
    if (mounted) setState(() {});
  }

  Widget _options(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: children),
        ],
      ),
    );
  }

  Widget _choice(String label, bool selected, FutureOr<void> Function() onPressed) {
    return StaticTextButton(
      label: label,
      selected: selected,
      onPressed: () {
        unawaited(Future<void>.sync(onPressed));
      },
    );
  }
}

class _TocNode {
  _TocNode(this.heading);

  final ChapterHeading heading;
  final List<_TocNode> children = [];
}

List<_TocNode> _tocTree(List<ChapterHeading> headings) {
  final roots = <_TocNode>[];
  _TocNode? section;
  for (final heading in headings) {
    final node = _TocNode(heading);
    if (heading.level <= 3) {
      section = node;
      roots.add(node);
    } else if (section != null) {
      section.children.add(node);
    } else {
      roots.add(node);
    }
  }
  return roots;
}

Uri googleSearchUrl(String text) => Uri.https('www.google.com', '/search', {'q': text});

/// Chinese text goes to the Chinese Wikipedia in Hong Kong script, anything else to the English one.
Uri wikiSearchUrl(String text) {
  final chinese = RegExp(r'[\u3400-\u9FFF\uF900-\uFAFF]').hasMatch(text);
  return chinese
      ? Uri.https('zh.wikipedia.org', '/zh-hk/Special:Search', {'search': text})
      : Uri.https('en.wikipedia.org', '/wiki/Special:Search', {'search': text});
}

bool isSinglePageStep({
  required int fromChapter,
  required int fromPage,
  required int fromPageCount,
  required int toChapter,
  required int toPage,
  required int toPageCount,
}) {
  if (fromPageCount <= 0 || toPageCount <= 0) return false;
  if (fromChapter == toChapter && fromPage == toPage) return true;
  if (fromChapter == toChapter && (fromPage - toPage).abs() == 1) return true;
  if (toChapter == fromChapter + 1 && fromPage == fromPageCount - 1 && toPage == 0) {
    return true;
  }
  if (toChapter == fromChapter - 1 && fromPage == 0 && toPage == toPageCount - 1) {
    return true;
  }
  return false;
}

class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.paper,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(controlRadius),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 20, color: colors.ink),
          ),
        ),
      ),
    );
  }
}

/// An icon in the bottom bar, as tall as the text buttons beside it.
class _BarIconButton extends StatelessWidget {
  const _BarIconButton({required this.icon, required this.label, required this.selected, required this.onPressed});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? colors.fill : colors.paper,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(controlRadius),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Icon(icon, size: 20, color: selected ? colors.onFill : colors.ink),
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.fill,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(controlRadius),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onFill, fontSize: 18, decoration: TextDecoration.none),
            ),
          ),
        ),
      ),
    );
  }
}
