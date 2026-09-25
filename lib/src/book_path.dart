/// Paths inside an EPUB use `/`, even when the book is an unzipped folder.
String? safeBookPath(String raw) {
  final parts = <String>[];
  for (final part in raw.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  if (parts.isEmpty) return null;
  return parts.join('/');
}

String parentBookPath(String path) {
  final index = path.lastIndexOf('/');
  if (index <= 0) return '';
  return path.substring(0, index);
}

String? resolveBookHref(String baseDir, String href) {
  final noFragment = href.split('#').first.split('?').first.trim();
  if (noFragment.isEmpty) return null;
  String decoded;
  try {
    decoded = Uri.decodeFull(noFragment);
  } catch (_) {
    decoded = noFragment;
  }
  if (decoded.startsWith('/')) return safeBookPath(decoded);
  final combined = baseDir.isEmpty ? decoded : '$baseDir/$decoded';
  return safeBookPath(combined);
}

String fileStem(String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return name;
  return name.substring(0, dot);
}

String? normalizeZipName(String name) {
  return safeBookPath(name.replaceAll('\\', '/'));
}
