import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'book_path.dart';

abstract class BookFiles {
  Future<List<int>?> read(String bookPath);
}

class MemoryBookFiles implements BookFiles {
  MemoryBookFiles(Map<String, List<int>> files) : _files = files;

  final Map<String, List<int>> _files;

  @override
  Future<List<int>?> read(String bookPath) async {
    final safe = safeBookPath(bookPath) ?? bookPath;
    return _files[safe] ?? _files[bookPath];
  }
}

class DirectoryBookFiles implements BookFiles {
  DirectoryBookFiles(this.root);

  final String root;

  @override
  Future<List<int>?> read(String bookPath) async {
    final safe = safeBookPath(bookPath);
    if (safe == null) return null;
    final file = File(p.join(root, safe.split('/').join(p.separator)));
    final rootReal = p.normalize(p.absolute(root));
    final fileReal = p.normalize(file.absolute.path);
    final inside = fileReal == rootReal || p.isWithin(rootReal, fileReal);
    if (!inside || !await file.exists()) return null;
    return file.readAsBytes();
  }
}

class ZipBookFiles implements BookFiles {
  ZipBookFiles(this._files);

  final Map<String, List<int>> _files;

  @override
  Future<List<int>?> read(String bookPath) async {
    final safe = safeBookPath(bookPath);
    if (safe == null) return null;
    return _files[safe];
  }
}

Map<String, List<int>> decodeZipBytes(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  final files = <String, List<int>>{};
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final name = normalizeZipName(entry.name);
    if (name == null) continue;
    final content = entry.content;
    if (content is Uint8List) {
      files[name] = content;
    } else if (content is List<int>) {
      files[name] = List<int>.from(content);
    }
  }
  return files;
}

Future<ZipBookFiles> openZipBook(String path) async {
  final bytes = await File(path).readAsBytes();
  try {
    return ZipBookFiles(await Isolate.run(() => decodeZipBytes(bytes)));
  } catch (_) {
    return ZipBookFiles(decodeZipBytes(bytes));
  }
}
