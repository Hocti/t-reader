import 'dart:convert';

import 'package:xml/xml.dart';

import 'book_files.dart';
import 'book_path.dart';

class ChapterRef {
  const ChapterRef({required this.path, required this.label});

  final String path;
  final String label;
}

/// One entry of the book's own table of contents.
class TocEntry {
  const TocEntry({required this.label, required this.path, this.fragment, this.children = const []});

  final String label;
  final String path;
  final String? fragment;
  final List<TocEntry> children;
}

class ParsedBook {
  const ParsedBook({this.title, this.chapters = const [], this.toc = const [], this.coverPath, this.failure});

  final String? title;
  final List<ChapterRef> chapters;

  /// From the nav document, else the NCX. Empty when the book has neither.
  final List<TocEntry> toc;
  final String? coverPath;
  final String? failure;

  bool get ok => failure == null && chapters.isNotEmpty;
}

Future<ParsedBook> parseBook(BookFiles files) async {
  try {
    final container = await _readText(files, 'META-INF/container.xml');
    if (container == null) {
      return const ParsedBook(failure: 'book.no_container');
    }
    final opfPath = _rootfilePath(container);
    if (opfPath == null) {
      return const ParsedBook(failure: 'book.bad_package');
    }
    final opf = await _readText(files, opfPath);
    if (opf == null) {
      return const ParsedBook(failure: 'book.bad_package');
    }
    return await _parseOpf(
      opfPath: opfPath,
      opf: opf,
      readText: (path) => _readText(files, path),
    );
  } catch (_) {
    return const ParsedBook(failure: 'book.bad_opf');
  }
}

Future<ParsedBook> _parseOpf({
  required String opfPath,
  required String opf,
  required Future<String?> Function(String path) readText,
}) async {
  final document = XmlDocument.parse(_stripBom(opf));
  final title = _firstText(document, 'title');
  final manifest = _childMap(document, 'manifest', 'item');
  final spine = _firstLocal(document, 'spine');
  if (spine == null) {
    return ParsedBook(title: title, failure: 'book.no_chapters');
  }

  final opfDir = parentBookPath(opfPath);
  final chapters = <ChapterRef>[];
  final seen = <String>{};
  for (final ref in spine.childElements) {
    if (ref.name.local != 'itemref') continue;
    final id = ref.getAttribute('idref');
    if (id == null) continue;
    final item = manifest[id];
    if (item == null) continue;
    final href = item.getAttribute('href');
    if (href == null) continue;
    if (!_isHtml(href, item.getAttribute('media-type'))) continue;
    final path = resolveBookHref(opfDir, href);
    if (path == null || !seen.add(path)) continue;
    chapters.add(ChapterRef(path: path, label: fileStem(path)));
  }

  if (chapters.isEmpty) {
    return ParsedBook(title: title, failure: 'book.no_chapters');
  }

  final contents = await _contents(
    manifest: manifest.values,
    opfDir: opfDir,
    readText: readText,
  );
  final labels = <String, String>{};
  for (final list in [contents.nav, contents.ncx]) {
    _flatten(list, (entry) => labels.putIfAbsent(entry.path, () => entry.label));
  }
  // A file the contents skip takes the label of the entry before it.
  final named = <ChapterRef>[];
  String? previous;
  for (final chapter in chapters) {
    final own = labels[chapter.path];
    if (own != null) previous = own;
    named.add(ChapterRef(path: chapter.path, label: own ?? previous ?? chapter.label));
  }
  return ParsedBook(
    title: title,
    chapters: named,
    toc: contents.nav.isNotEmpty ? contents.nav : contents.ncx,
    coverPath: _coverPath(document, manifest, opfDir),
  );
}

void _flatten(List<TocEntry> entries, void Function(TocEntry entry) visit) {
  for (final entry in entries) {
    visit(entry);
    _flatten(entry.children, visit);
  }
}

/// `meta name="cover"` stores a manifest id. `properties="cover-image"` is the fallback.
String? _coverPath(XmlDocument document, Map<String, XmlElement> manifest, String opfDir) {
  String? id;
  for (final node in document.descendants.whereType<XmlElement>()) {
    if (node.name.local != 'meta') continue;
    if (node.getAttribute('name') != 'cover') continue;
    id = node.getAttribute('content');
    break;
  }
  if (id != null) {
    final href = manifest[id]?.getAttribute('href');
    final path = href == null ? null : resolveBookHref(opfDir, href);
    if (path != null) return path;
  }
  for (final item in manifest.values) {
    final properties = item.getAttribute('properties') ?? '';
    if (!properties.split(RegExp(r'\s+')).contains('cover-image')) continue;
    final href = item.getAttribute('href');
    if (href == null) continue;
    return resolveBookHref(opfDir, href);
  }
  return null;
}

Future<({List<TocEntry> nav, List<TocEntry> ncx})> _contents({
  required Iterable<XmlElement> manifest,
  required String opfDir,
  required Future<String?> Function(String path) readText,
}) async {
  var nav = const <TocEntry>[];
  var ncx = const <TocEntry>[];
  String? navPath;
  String? ncxPath;
  for (final item in manifest) {
    final href = item.getAttribute('href');
    if (href == null) continue;
    final path = resolveBookHref(opfDir, href);
    if (path == null) continue;
    final properties = item.getAttribute('properties') ?? '';
    final type = (item.getAttribute('media-type') ?? '').toLowerCase();
    if (navPath == null && properties.split(RegExp(r'\s+')).contains('nav')) {
      navPath = path;
    }
    if (ncxPath == null && type.contains('ncx')) ncxPath = path;
  }

  if (navPath != null) {
    final text = await readText(navPath);
    if (text != null) {
      try {
        nav = readNav(text, parentBookPath(navPath));
      } catch (_) {}
    }
  }
  if (ncxPath != null) {
    final text = await readText(ncxPath);
    if (text != null) {
      try {
        ncx = readNcx(text, parentBookPath(ncxPath));
      } catch (_) {}
    }
  }
  return (nav: nav, ncx: ncx);
}

/// The `toc` nav of an EPUB 3 nav document, nested as the book nests it.
List<TocEntry> readNav(String xml, String baseDir) {
  final document = XmlDocument.parse(_stripBom(xml));
  final navs = document.descendants.whereType<XmlElement>().where((node) => node.name.local == 'nav').toList();
  if (navs.isEmpty) return const [];
  final nav = navs.firstWhere((node) => _attrLocal(node, 'type').split(RegExp(r'\s+')).contains('toc'), orElse: () => navs.first);
  final list = _firstLocal(nav, 'ol') ?? _firstLocal(nav, 'ul');
  if (list == null) return const [];
  return _navList(list, baseDir);
}

List<TocEntry> _navList(XmlElement list, String baseDir) {
  final entries = <TocEntry>[];
  for (final item in list.childElements) {
    if (item.name.local != 'li') continue;
    XmlElement? head;
    XmlElement? sub;
    for (final child in item.childElements) {
      final name = child.name.local;
      if (head == null && (name == 'a' || name == 'span')) head = child;
      if (sub == null && (name == 'ol' || name == 'ul')) sub = child;
    }
    final children = sub == null ? const <TocEntry>[] : _navList(sub, baseDir);
    final label = _clean(head?.innerText);
    final href = head?.getAttribute('href');
    final target = href == null ? null : _target(baseDir, href);
    if (label == null || (target == null && children.isEmpty)) {
      entries.addAll(children);
      continue;
    }
    entries.add(
      TocEntry(
        label: label,
        path: target?.path ?? children.first.path,
        fragment: target == null ? children.first.fragment : target.fragment,
        children: children,
      ),
    );
  }
  return entries;
}

List<TocEntry> readNcx(String xml, String baseDir) {
  final document = XmlDocument.parse(_stripBom(xml));
  final map = _firstLocal(document, 'navMap');
  if (map == null) return const [];
  return _ncxPoints(map, baseDir);
}

List<TocEntry> _ncxPoints(XmlElement parent, String baseDir) {
  final entries = <TocEntry>[];
  for (final point in parent.childElements) {
    if (point.name.local != 'navPoint') continue;
    String? label;
    String? href;
    for (final child in point.childElements) {
      if (child.name.local == 'navLabel') label = _clean(child.innerText);
      if (child.name.local == 'content') href = child.getAttribute('src');
    }
    final children = _ncxPoints(point, baseDir);
    final target = href == null ? null : _target(baseDir, href);
    if (label == null || target == null) {
      entries.addAll(children);
      continue;
    }
    entries.add(TocEntry(label: label, path: target.path, fragment: target.fragment, children: children));
  }
  return entries;
}

({String path, String? fragment})? _target(String baseDir, String href) {
  final path = resolveBookHref(baseDir, href);
  if (path == null) return null;
  final hash = href.indexOf('#');
  final raw = hash < 0 ? '' : href.substring(hash + 1);
  if (raw.isEmpty) return (path: path, fragment: null);
  try {
    return (path: path, fragment: Uri.decodeComponent(raw));
  } catch (_) {
    return (path: path, fragment: raw);
  }
}

bool _isHtml(String href, String? mediaType) {
  final type = (mediaType ?? '').toLowerCase();
  if (type.contains('ncx') || type.startsWith('image/') || type == 'text/css') {
    return false;
  }
  final lower = href.toLowerCase().split('#').first;
  return type.contains('html') ||
      lower.endsWith('.xhtml') ||
      lower.endsWith('.html') ||
      lower.endsWith('.htm');
}

String? _rootfilePath(String container) {
  final document = XmlDocument.parse(_stripBom(container));
  for (final node in document.descendants.whereType<XmlElement>()) {
    if (node.name.local != 'rootfile') continue;
    final fullPath = node.getAttribute('full-path');
    if (fullPath != null && fullPath.trim().isNotEmpty) {
      return safeBookPath(fullPath.trim()) ?? fullPath.trim();
    }
  }
  return null;
}

Map<String, XmlElement> _childMap(XmlNode document, String parent, String child) {
  final found = _firstLocal(document, parent);
  final map = <String, XmlElement>{};
  if (found == null) return map;
  for (final node in found.childElements) {
    if (node.name.local != child) continue;
    final id = node.getAttribute('id');
    if (id != null) map[id] = node;
  }
  return map;
}

XmlElement? _firstLocal(XmlNode node, String name) {
  for (final element in node.descendants.whereType<XmlElement>()) {
    if (element.name.local == name) return element;
  }
  return null;
}

String? _firstText(XmlNode node, String name) {
  final element = _firstLocal(node, name);
  if (element == null) return null;
  return _clean(element.innerText);
}

String _attrLocal(XmlElement node, String name) {
  for (final attribute in node.attributes) {
    if (attribute.name.local == name) return attribute.value;
  }
  return '';
}

String? _clean(String? raw) {
  if (raw == null) return null;
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return null;
  return text;
}

String _stripBom(String value) {
  if (value.startsWith('\uFEFF')) return value.substring(1);
  return value;
}

Future<String?> _readText(BookFiles files, String path) async {
  final bytes = await files.read(path);
  if (bytes == null) return null;
  return utf8.decode(bytes, allowMalformed: true);
}
