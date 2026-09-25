import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../i18n.dart';
import '../widgets.dart';

class FolderPage extends StatefulWidget {
  const FolderPage({super.key});

  @override
  State<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends State<FolderPage> with WidgetsBindingObserver {
  var _checking = true;
  var _allowed = false;
  String _current = '/';
  List<Directory> _children = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final allowed = await hasFileAccess();
    if (!mounted) return;
    setState(() {
      _allowed = allowed;
      _checking = false;
    });
    if (allowed) {
      await _load(_current == '/' ? initialBrowsePath() : _current);
    }
  }

  Future<void> _request() async {
    final allowed = await requestFileAccess();
    if (!mounted) return;
    setState(() => _allowed = allowed);
    if (allowed) await _load(initialBrowsePath());
  }

  Future<void> _load(String path) async {
    final directory = Directory(path);
    try {
      final children = directory
          .listSync(followLinks: false)
          .whereType<Directory>()
          .toList();
      children.sort(
        (a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()),
      );
      if (!mounted) return;
      setState(() {
        _current = path;
        _children = children;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _current = path;
        _children = const [];
        _error = 'folder.unreadable';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    final atRoot = p.dirname(_current) == _current;
    return Scaffold(
      backgroundColor: colors.paper,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Align(alignment: Alignment.centerLeft, child: BackLabel()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(tr(context, 'folder.title'), style: const TextStyle(fontSize: 22, height: 1.2)),
            ),
            if (_checking)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(tr(context, 'folder.checking'), style: const TextStyle(fontSize: 14)),
              )
            else if (!_allowed)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'folder.need_access'),
                      style: const TextStyle(fontSize: 16, height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    StaticTextButton(
                      label: tr(context, 'folder.allow'),
                      emphasize: true,
                      onPressed: _request,
                    ),
                  ],
                ),
              )
            else
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SelectableText(_current),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          StaticTextButton(
                            label: tr(context, 'folder.up'),
                            onPressed: atRoot ? null : () => _load(p.dirname(_current)),
                          ),
                          StaticTextButton(
                            label: tr(context, 'folder.use'),
                            emphasize: true,
                            onPressed: () => Navigator.of(context).pop(_current),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(tr(context, _error!), style: const TextStyle(fontSize: 14)),
                      ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          if (_children.isEmpty && _error == null)
                            Text(tr(context, 'folder.empty'), style: const TextStyle(fontSize: 14)),
                          for (final child in _children)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: StaticTextButton(
                                label: p.basename(child.path),
                                expand: true,
                                onPressed: () => _load(child.path),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String initialBrowsePath() {
  const candidates = ['/storage/emulated/0', '/sdcard', '/storage'];
  for (final candidate in candidates) {
    if (Directory(candidate).existsSync()) return candidate;
  }
  return '/';
}

Future<bool> hasFileAccess() async {
  if (!Platform.isAndroid) return true;
  if (await Permission.manageExternalStorage.isGranted) return true;
  if (await Permission.storage.isGranted) return true;
  return false;
}

Future<bool> requestFileAccess() async {
  if (!Platform.isAndroid) return true;
  final manage = await Permission.manageExternalStorage.request();
  if (manage.isGranted) return true;
  final storage = await Permission.storage.request();
  return storage.isGranted;
}
