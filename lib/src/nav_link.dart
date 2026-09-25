import 'book_path.dart';

class NavChoice {
  const NavChoice.allow() : chapterIndex = null, blocked = false;

  const NavChoice.block() : chapterIndex = null, blocked = true;

  const NavChoice.chapter(this.chapterIndex) : blocked = false;

  final int? chapterIndex;
  final bool blocked;
}

/// Decides what a WebView navigation may do.
/// Links to another spine item become that chapter. Links off this book are blocked.
NavChoice decideBookNavigation({
  required String requestUrl,
  required int port,
  required List<String> chapterPaths,
}) {
  final uri = Uri.tryParse(requestUrl);
  if (uri == null) return const NavChoice.block();
  if (uri.scheme == 'about') return const NavChoice.allow();
  if (uri.scheme != 'http') return const NavChoice.block();
  if (uri.host != '127.0.0.1' && uri.host != 'localhost') {
    return const NavChoice.block();
  }
  if (uri.hasPort && uri.port != port) return const NavChoice.block();

  final path = safeBookPath(uri.path);
  if (path == null) return const NavChoice.allow();
  final index = chapterPaths.indexOf(path);
  if (index >= 0) return NavChoice.chapter(index);
  return const NavChoice.allow();
}
