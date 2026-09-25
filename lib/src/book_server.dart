import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'book_files.dart';
import 'page_paint.dart';

class BookServer {
  BookServer({required this.files, required this.paint});

  final BookFiles files;
  PagePaint paint;
  final Map<String, List<int>> _prepared = {};
  HttpServer? _server;

  void setPrepared(String path, List<int> bytes) {
    _prepared[path] = bytes;
  }

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    final server = await shelf_io.serve(_handle, InternetAddress.loopbackIPv4, 0);
    _server = server;
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<Response> _handle(Request request) async {
    final path = requestBookPath(request.url);
    if (path == null) return Response.notFound('missing');
    final prepared = _prepared[path];
    if (prepared != null) {
      return Response.ok(
        prepared,
        headers: {
          HttpHeaders.contentTypeHeader: contentTypeFor(path),
          HttpHeaders.cacheControlHeader: 'no-store',
        },
      );
    }
    final bytes = await files.read(path);
    if (bytes == null) return Response.notFound('missing');
    final body = isHtmlPath(path) ? paintHtml(bytes, paint) : bytes;
    return Response.ok(
      body,
      headers: {
        HttpHeaders.contentTypeHeader: contentTypeFor(path),
        HttpHeaders.cacheControlHeader: 'no-store',
      },
    );
  }
}
