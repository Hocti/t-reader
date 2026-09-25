import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'book_data.dart';

/// Only files this app made. Google does not review apps for this scope.
const _scope = 'https://www.googleapis.com/auth/drive.file';
const driveFolderName = 'EPUB Reader';
const _api = 'https://www.googleapis.com/drive/v3/files';
const _upload = 'https://www.googleapis.com/upload/drive/v3/files';

/// [key] is a line in `strings.csv`.
class DriveException implements Exception {
  const DriveException(this.key);

  final String key;
}

class _Remote {
  const _Remote(this.id, this.modified);

  final String id;
  final String modified;
}

/// Keeps the per-book files the same in the local folder and in the `EPUB Reader` folder on Google Drive.
class DriveSync {
  DriveSync({GoogleSignIn? signIn}) : _signIn = signIn ?? GoogleSignIn(scopes: const [_scope]);

  static const _stateKey = 'drive_state_v1';

  final GoogleSignIn _signIn;
  GoogleSignInAccount? _account;

  String? get email => _account?.email;

  /// Opens Google's account picker. Null when the user backs out.
  Future<String?> connect() async {
    try {
      _account = await _signIn.signIn();
    } on PlatformException catch (error) {
      if (error.code == GoogleSignIn.kSignInCanceledError) return null;
      // Status 10 means this app's package and signing key are not registered in Google Cloud.
      if ('${error.message} ${error.details}'.contains('ApiException: 10')) throw const DriveException('drive.not_set_up');
      if (error.code == GoogleSignIn.kNetworkError) throw const DriveException('drive.offline');
      throw const DriveException('drive.failed');
    }
    return _account?.email;
  }

  /// Signs in again without asking, at app start.
  Future<bool> resume() async {
    try {
      _account ??= await _signIn.signInSilently();
    } catch (_) {}
    return _account != null;
  }

  Future<void> disconnect() async {
    try {
      await _signIn.disconnect();
    } catch (_) {
      try {
        await _signIn.signOut();
      } catch (_) {}
    }
    _account = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_stateKey);
  }

  /// Downloads what changed on Drive, merges it into [store], and uploads what changed here.
  /// Returns the file names whose local copy changed.
  Future<Set<String>> sync(BookDataStore store) async {
    if (_account == null && !await resume()) throw const DriveException('drive.signed_out');
    final prefs = await SharedPreferences.getInstance();
    final state = _readState(prefs.getString(_stateKey));
    if (state['account'] != email) {
      state
        ..clear()
        ..['account'] = email;
    }
    final files = (state['files'] as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
    state['files'] = files;
    await store.flush();
    try {
      final folder = await _folder(state);
      final remote = await _list(folder);
      final names = {...remote.keys, ...await store.fileNames()};
      final changed = <String>{};
      for (final name in names) {
        final there = remote[name];
        final seen = files[name] is Map ? (files[name] as Map).cast<String, Object?>() : null;
        final local = await store.readFile(name);
        BookData? theirs;
        if (there != null && (seen == null || seen['id'] != there.id || seen['modified'] != there.modified)) {
          theirs = BookData.decode(await _download(there.id), title: name.replaceAll(RegExp(r'\.json$'), ''));
        }
        var merged = local;
        if (theirs != null) {
          merged = await store.put(name, theirs);
          if (local == null || local.encode() != merged.encode()) changed.add(name);
        }
        if (merged == null) continue;
        final text = merged.encode();
        final hash = _hash(text);
        final send = there == null || (theirs != null ? theirs.encode() != text : seen?['hash'] != hash);
        var id = there?.id;
        var modified = there?.modified;
        if (send) {
          final sent = await _put(folder, name, text, id: id);
          id = sent.id;
          modified = sent.modified;
        }
        files[name] = {'id': id, 'modified': modified, 'hash': hash};
      }
      return changed;
    } finally {
      await prefs.setString(_stateKey, jsonEncode(state));
    }
  }

  Map<String, Object?> _readState(String? raw) {
    if (raw == null) return {};
    try {
      final json = jsonDecode(raw);
      if (json is Map) return json.cast<String, Object?>();
    } catch (_) {}
    return {};
  }

  Future<String> _folder(Map<String, Object?> state) async {
    final known = state['folder'];
    if (known is String) {
      final check = await _call('GET', Uri.parse('$_api/$known?fields=id,trashed'), allowMissing: true);
      if (check.statusCode == 200 && (jsonDecode(check.body) as Map)['trashed'] != true) return known;
    }
    final q = "name = '$driveFolderName' and mimeType = 'application/vnd.google-apps.folder' and trashed = false";
    final found = await _call('GET', Uri.parse(_api).replace(queryParameters: {'q': q, 'fields': 'files(id)', 'spaces': 'drive'}));
    final list = (jsonDecode(found.body) as Map)['files'];
    String? id;
    if (list is List && list.isNotEmpty && list.first is Map) id = (list.first as Map)['id'] as String?;
    if (id == null) {
      final made = await _call(
        'POST',
        Uri.parse('$_api?fields=id'),
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: utf8.encode(jsonEncode({'name': driveFolderName, 'mimeType': 'application/vnd.google-apps.folder'})),
      );
      id = (jsonDecode(made.body) as Map)['id'] as String?;
    }
    if (id == null) throw const DriveException('drive.failed');
    state['folder'] = id;
    return id;
  }

  Future<Map<String, _Remote>> _list(String folder) async {
    final out = <String, _Remote>{};
    String? token;
    do {
      final uri = Uri.parse(_api).replace(queryParameters: {
        'q': "'$folder' in parents and trashed = false",
        'fields': 'nextPageToken,files(id,name,modifiedTime)',
        'pageSize': '1000',
        'spaces': 'drive',
        if (token != null) 'pageToken': token,
      });
      final response = await _call('GET', uri);
      final json = jsonDecode(response.body) as Map;
      final files = json['files'];
      if (files is List) {
        for (final file in files) {
          if (file is! Map) continue;
          final name = file['name'];
          final id = file['id'];
          final modified = file['modifiedTime'];
          if (name is String && id is String && name.endsWith('.json')) {
            out.putIfAbsent(name, () => _Remote(id, modified is String ? modified : ''));
          }
        }
      }
      token = json['nextPageToken'] as String?;
    } while (token != null);
    return out;
  }

  Future<String> _download(String id) async {
    final response = await _call('GET', Uri.parse('$_api/$id?alt=media'));
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  Future<_Remote> _put(String folder, String name, String text, {String? id}) async {
    final http.Response response;
    if (id != null) {
      response = await _call(
        'PATCH',
        Uri.parse('$_upload/$id?uploadType=media&fields=id,modifiedTime'),
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: utf8.encode(text),
      );
    } else {
      const boundary = 'epub-reader-part';
      final meta = jsonEncode({
        'name': name,
        'parents': [folder],
        'mimeType': 'application/json',
      });
      final body = '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n$meta\r\n'
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n$text\r\n'
          '--$boundary--';
      response = await _call(
        'POST',
        Uri.parse('$_upload?uploadType=multipart&fields=id,modifiedTime'),
        headers: {'Content-Type': 'multipart/related; boundary=$boundary'},
        body: utf8.encode(body),
      );
    }
    final json = jsonDecode(response.body) as Map;
    return _Remote(json['id'] as String, (json['modifiedTime'] as String?) ?? '');
  }

  /// Signs in again once when Google says the token ran out.
  Future<http.Response> _call(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
    bool allowMissing = false,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final account = _account;
      if (account == null) throw const DriveException('drive.signed_out');
      final Map<String, String> auth;
      try {
        auth = await account.authHeaders;
      } catch (_) {
        throw const DriveException('drive.signed_out');
      }
      final request = http.Request(method, uri)..headers.addAll({...auth, ...headers});
      if (body != null) request.bodyBytes = body;
      final http.Response response;
      try {
        response = await http.Response.fromStream(await request.send().timeout(const Duration(seconds: 30)));
      } catch (_) {
        throw const DriveException('drive.offline');
      }
      if (response.statusCode == 401 && attempt == 0) {
        await account.clearAuthCache();
        continue;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) return response;
      if (allowMissing && response.statusCode == 404) return response;
      throw const DriveException('drive.failed');
    }
    throw const DriveException('drive.signed_out');
  }
}

/// FNV-1a over the UTF-8 bytes.
String _hash(String text) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(text)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
