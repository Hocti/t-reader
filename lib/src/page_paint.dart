import 'dart:convert';

import 'book_path.dart';

class PagePaint {
  const PagePaint({
    required this.page,
    required this.ink,
    this.accent,
    this.onAccent,
    this.word,
    this.onWord,
  });

  final String page;
  final String ink;
  final String? accent;
  final String? onAccent;
  final String? word;
  final String? onWord;

  /// Background of the selection and the sentence being read.
  String get accentCss => accent ?? ink;
  String get onAccentCss => onAccent ?? page;

  /// The word being spoken, inside the sentence being read. Without its own color it is the sentence inverted.
  String get wordCss => word ?? page;
  String get onWordCss => onWord ?? ink;
}

String contentTypeFor(String bookPath) {
  final lower = bookPath.toLowerCase();
  if (lower.endsWith('.css')) return 'text/css; charset=utf-8';
  if (lower.endsWith('.xhtml') || lower.endsWith('.html') || lower.endsWith('.htm')) {
    return 'application/xhtml+xml; charset=utf-8';
  }
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  if (lower.endsWith('.js')) return 'text/javascript; charset=utf-8';
  if (lower.endsWith('.ncx')) return 'application/x-dtbncx+xml';
  return 'application/octet-stream';
}

bool isHtmlPath(String bookPath) {
  final lower = bookPath.toLowerCase();
  return lower.endsWith('.xhtml') || lower.endsWith('.html') || lower.endsWith('.htm');
}

String themeStyle(PagePaint paint) {
  return '''
<style id="epub-reader-theme">
html, body { background: ${paint.page} !important; color: ${paint.ink} !important; }
body, body * { color: ${paint.ink} !important; background-color: transparent !important; }
a { text-decoration: underline !important; }
</style>
''';
}

List<int> paintHtml(List<int> bytes, PagePaint paint) {
  final html = utf8.decode(bytes, allowMalformed: true);
  final extra = StringBuffer(themeStyle(paint));
  final lower = html.toLowerCase();
  if (!lower.contains('name="viewport"') && !lower.contains("name='viewport'")) {
    extra.write(
      '<meta name="viewport" content="width=device-width, initial-scale=1">',
    );
  }
  final head = RegExp(r'</head>', caseSensitive: false);
  final painted = head.hasMatch(html)
      ? html.replaceFirst(head, '$extra</head>')
      : '$extra$html';
  return utf8.encode(painted);
}

String bookUrl({
  required int port,
  required String bookPath,
  required String themeKey,
  int revision = 0,
}) {
  final encoded = bookPath.split('/').map(Uri.encodeComponent).join('/');
  return 'http://127.0.0.1:$port/$encoded?theme=$themeKey&rev=$revision';
}

String? requestBookPath(Uri uri) => safeBookPath(uri.path);
