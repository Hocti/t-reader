import 'package:flutter/services.dart';

const _channel = MethodChannel('epub_reader/open');

/// Books opened from another app. [onBook] gets a readable `.epub` path: the file itself,
/// or a copy in this app's storage when the file cannot be read directly.
/// Returns the book the app was started with, if any.
Future<String?> listenForOpenedBooks(void Function(String path) onBook) async {
  _channel.setMethodCallHandler((call) async {
    final path = call.arguments;
    if (call.method == 'open' && path is String && path.isNotEmpty) onBook(path);
  });
  try {
    final path = await _channel.invokeMethod<String>('initial');
    return path == null || path.isEmpty ? null : path;
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
