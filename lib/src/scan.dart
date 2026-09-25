import 'dart:io';

import 'package:path/path.dart' as p;

class BookLocation {
  const BookLocation({
    required this.path,
    required this.zipped,
    required this.fallbackTitle,
    required this.modified,
    this.size = 0,
  });

  final String path;
  final bool zipped;
  final String fallbackTitle;
  final DateTime modified;
  final int size;

  /// Changes when the file or folder changes. Cached metadata keys on it.
  String get stamp => '${modified.millisecondsSinceEpoch}:$size';
}

class ShelfScan {
  const ShelfScan({
    required this.books,
    required this.missing,
    required this.unreadable,
  });

  final List<BookLocation> books;
  final List<String> missing;
  final List<String> unreadable;
}

/// Books in the first level of [directories] only.
/// An `.epub` file is one book. A folder that contains `mimetype` is one book.
ShelfScan scanDirectories(List<String> directories) {
  final books = <BookLocation>[];
  final seen = <String>{};
  final missing = <String>[];
  final unreadable = <String>[];

  for (final raw in directories) {
    final path = canonicalPath(raw);
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      missing.add(path);
      continue;
    }
    if (type != FileSystemEntityType.directory) {
      unreadable.add(path);
      continue;
    }
    final directory = Directory(path);
    try {
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (!name.toLowerCase().endsWith('.epub')) continue;
          _addBook(
            books,
            seen,
            path: canonicalPath(entity.path),
            zipped: true,
            fallbackTitle: _stem(name),
            modified: _modified(entity),
            size: _size(entity),
          );
        } else if (entity is Directory && _hasMimetype(entity)) {
          final name = p.basename(entity.path);
          _addBook(
            books,
            seen,
            path: canonicalPath(entity.path),
            zipped: false,
            fallbackTitle: name,
            modified: _modified(entity),
          );
        }
      }
    } on FileSystemException {
      unreadable.add(path);
    }
  }

  return ShelfScan(books: books, missing: missing, unreadable: unreadable);
}

/// Single `.epub` files opened from another app. A missing file is left out.
List<BookLocation> scanFiles(List<String> files, {Set<String> skip = const {}}) {
  final books = <BookLocation>[];
  final seen = {...skip};
  for (final raw in files) {
    final path = canonicalPath(raw);
    final file = File(path);
    if (!file.existsSync()) continue;
    _addBook(
      books,
      seen,
      path: path,
      zipped: true,
      fallbackTitle: _stem(p.basename(path)),
      modified: _modified(file),
      size: _size(file),
    );
  }
  return books;
}

void _addBook(
  List<BookLocation> books,
  Set<String> seen, {
  required String path,
  required bool zipped,
  required String fallbackTitle,
  required DateTime modified,
  int size = 0,
}) {
  if (!seen.add(path)) return;
  books.add(
    BookLocation(
      path: path,
      zipped: zipped,
      fallbackTitle: fallbackTitle.isEmpty ? p.basename(path) : fallbackTitle,
      modified: modified,
      size: size,
    ),
  );
}

int _size(File file) {
  try {
    return file.lengthSync();
  } catch (_) {
    return 0;
  }
}

DateTime _modified(FileSystemEntity entity) {
  try {
    return entity.statSync().modified;
  } catch (_) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

bool _hasMimetype(Directory directory) {
  try {
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is File && p.basename(entity.path).toLowerCase() == 'mimetype') {
        return true;
      }
    }
  } on FileSystemException {
    return false;
  }
  return false;
}

String _stem(String name) {
  final lower = name.toLowerCase();
  if (!lower.endsWith('.epub')) return name;
  final stem = name.substring(0, name.length - 5);
  return stem.isEmpty ? name : stem;
}

String canonicalPath(String path) {
  final normalized = p.normalize(p.absolute(path));
  try {
    if (File(normalized).existsSync()) {
      return File(normalized).resolveSymbolicLinksSync();
    }
    if (Directory(normalized).existsSync()) {
      return Directory(normalized).resolveSymbolicLinksSync();
    }
  } catch (_) {}
  return normalized;
}
