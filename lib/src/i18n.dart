import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'library_scope.dart';

/// UI copy from `assets/i18n/strings.csv`.
/// Columns after `key` are language codes, the same idea as i18next resources.
class AppText {
  static final List<String> languages = [];
  static final Map<String, Map<String, String>> _rows = {};

  static Future<void> load() async {
    loadString(await rootBundle.loadString('assets/i18n/strings.csv'));
  }

  static void loadString(String raw) {
    final rows = parseCsv(raw);
    languages.clear();
    _rows.clear();
    if (rows.isEmpty) return;
    final header = rows.first;
    if (header.isEmpty || header.first != 'key') return;
    languages.addAll(header.skip(1).where((code) => code.isNotEmpty));
    for (final row in rows.skip(1)) {
      if (row.isEmpty || row.first.isEmpty) continue;
      final values = <String, String>{};
      for (var i = 0; i < languages.length; i++) {
        values[languages[i]] = i + 1 < row.length ? row[i + 1] : '';
      }
      _rows[row.first] = values;
    }
  }

  static String get(String language, String key, [Map<String, String> args = const {}]) {
    final row = _rows[key];
    if (row == null) return key;
    var text = row[language];
    if (text == null || text.isEmpty) text = row['zh-Hant'];
    if (text == null || text.isEmpty) {
      for (final value in row.values) {
        if (value.isNotEmpty) {
          text = value;
          break;
        }
      }
    }
    text ??= key;
    for (final entry in args.entries) {
      text = text!.replaceAll('{${entry.key}}', entry.value);
    }
    return text!;
  }
}

String tr(BuildContext context, String key, [Map<String, String> args = const {}]) {
  return AppText.get(LibraryScope.of(context).uiLanguage, key, args);
}

/// A small CSV reader: commas, quotes, and newlines inside quotes.
List<List<String>> parseCsv(String raw) {
  final rows = <List<String>>[];
  final row = <String>[];
  final cell = StringBuffer();
  var quotes = false;
  final text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (quotes) {
      if (char == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quotes = false;
        }
      } else {
        cell.write(char);
      }
      continue;
    }
    if (char == '"') {
      quotes = true;
    } else if (char == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (char == '\n' || char == '\r') {
      if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.any((value) => value.isNotEmpty)) rows.add(List.of(row));
      row.clear();
    } else {
      cell.write(char);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    if (row.any((value) => value.isNotEmpty)) rows.add(List.of(row));
  }
  return rows;
}
