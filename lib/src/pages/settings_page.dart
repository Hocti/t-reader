import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../i18n.dart';
import '../library.dart';
import '../library_scope.dart';
import '../widgets.dart';
import 'folder_page.dart';
import 'hidden_books_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  var _version = '…';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _version = info.version);
    } catch (_) {
      if (!mounted) return;
      setState(() => _version = '0.1.0');
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final colors = colorsOf(context);
    final hidden = library.hiddenBooks;
    final languages = AppText.languages.isEmpty ? const ['zh-Hant', 'en'] : AppText.languages;
    return Scaffold(
      backgroundColor: colors.paper,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Align(alignment: Alignment.centerLeft, child: BackLabel()),
            const SizedBox(height: 16),
            Text(tr(context, 'settings.title'), style: const TextStyle(fontSize: 22, height: 1.2)),
            const SizedBox(height: 20),
            Text(tr(context, 'settings.folders'), style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            if (library.directories.isEmpty)
              Text(tr(context, 'settings.no_folders'), style: const TextStyle(fontSize: 14))
            else
              for (final path in library.directories) ...[
                SelectableText(path, style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: StaticTextButton(
                    label: tr(context, 'settings.remove'),
                    onPressed: () => library.removeDirectory(path),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            Align(
              alignment: Alignment.centerLeft,
              child: StaticTextButton(
                label: tr(context, 'settings.add_folder'),
                emphasize: true,
                onPressed: () async {
                  final picked = await pushPage<String>(context, const FolderPage());
                  if (picked == null || !context.mounted) return;
                  await library.addDirectory(picked);
                },
              ),
            ),
            const SizedBox(height: 24),
            Text(tr(context, 'settings.theme'), style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text(tr(context, 'settings.theme_help'), style: const TextStyle(fontSize: 14, height: 1.4)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _theme(library, AppThemeKind.einkWhite, tr(context, 'settings.theme_white')),
                _theme(library, AppThemeKind.einkBlack, tr(context, 'settings.theme_black')),
                _theme(library, AppThemeKind.light, tr(context, 'settings.theme_light')),
                _theme(library, AppThemeKind.dark, tr(context, 'settings.theme_dark')),
              ],
            ),
            const SizedBox(height: 24),
            ChoiceGroup(
              caption: tr(context, 'settings.language'),
              options: [
                for (final code in languages)
                  ChoiceOption(
                    label: AppText.get(code, 'lang.$code'),
                    selected: library.uiLanguage == code,
                    onPressed: () => library.setUiLanguage(code),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            ChoiceGroup(
              caption: tr(context, 'settings.lookup_speak'),
              options: [
                for (final (value, key) in const [
                  (LookupSpeak.headphones, 'settings.lookup_speak_headphones'),
                  (LookupSpeak.always, 'settings.lookup_speak_always'),
                  (LookupSpeak.never, 'settings.lookup_speak_never'),
                ])
                  ChoiceOption(
                    label: tr(context, key),
                    selected: library.lookupSpeak == value,
                    onPressed: () => library.setLookupSpeak(value),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            ChoiceGroup(
              caption: tr(context, 'settings.keep_awake'),
              options: [
                ChoiceOption(label: tr(context, 'settings.on'), selected: library.keepAwake, onPressed: () => library.setKeepAwake(true)),
                ChoiceOption(label: tr(context, 'settings.off'), selected: !library.keepAwake, onPressed: () => library.setKeepAwake(false)),
              ],
            ),
            const SizedBox(height: 24),
            ChoiceGroup(
              caption: tr(context, 'settings.open_last'),
              options: [
                ChoiceOption(label: tr(context, 'settings.on'), selected: library.openLast, onPressed: () => library.setOpenLast(true)),
                ChoiceOption(label: tr(context, 'settings.off'), selected: !library.openLast, onPressed: () => library.setOpenLast(false)),
              ],
            ),
            const SizedBox(height: 24),
            _dataSection(library),
            const SizedBox(height: 24),
            _driveSection(library),
            const SizedBox(height: 24),
            Text(tr(context, 'settings.hidden'), style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            if (hidden.isEmpty)
              Text(tr(context, 'settings.none_hidden'), style: const TextStyle(fontSize: 14))
            else
              Align(
                alignment: Alignment.centerLeft,
                child: StaticTextButton(
                  label: tr(context, 'settings.hidden_count', {'n': '${hidden.length}'}),
                  onPressed: () => pushPage<void>(context, const HiddenBooksPage()),
                ),
              ),
            const SizedBox(height: 24),
            Text(tr(context, 'settings.version'), style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text(_version, style: const TextStyle(fontSize: 16)),
          ],
        ),
      ),
    );
  }

  /// One JSON file per book, all in this folder.
  Widget _dataSection(LibraryController library) {
    final custom = library.dataDir;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr(context, 'settings.data'), style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        Text(tr(context, 'settings.data_help'), style: const TextStyle(fontSize: 14, height: 1.4)),
        const SizedBox(height: 8),
        FutureBuilder(
          future: library.data.directory(),
          builder: (context, snapshot) => SelectableText(
            custom ?? snapshot.data?.path ?? '',
            style: const TextStyle(fontSize: 14),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            StaticTextButton(
              label: tr(context, 'settings.data_change'),
              onPressed: () async {
                final picked = await pushPage<String>(context, const FolderPage());
                if (picked == null || !mounted) return;
                await library.setDataDir(picked);
              },
            ),
            if (custom != null)
              StaticTextButton(
                label: tr(context, 'settings.data_default'),
                onPressed: () => library.setDataDir(null),
              ),
          ],
        ),
      ],
    );
  }

  Widget _driveSection(LibraryController library) {
    final synced = formatReadTime(library.driveSynced);
    final String status;
    if (library.driveBusy) {
      status = tr(context, 'drive.busy');
    } else if (library.driveError != null) {
      status = tr(context, library.driveError!);
    } else if (!library.driveOn) {
      status = tr(context, 'drive.off');
    } else if (synced != null) {
      status = tr(context, 'drive.synced', {'time': synced});
    } else {
      status = tr(context, 'drive.never');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr(context, 'settings.drive'), style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 8),
        Text(tr(context, 'settings.drive_help'), style: const TextStyle(fontSize: 14, height: 1.4)),
        const SizedBox(height: 8),
        if (library.driveOn && library.driveAccount != null) ...[
          Text(library.driveAccount!, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 4),
        ],
        Text(status, style: const TextStyle(fontSize: 14, height: 1.4)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: library.driveOn
              ? [
                  StaticTextButton(
                    label: tr(context, 'drive.sync_now'),
                    onPressed: library.driveBusy ? null : () => library.syncNow(),
                  ),
                  StaticTextButton(label: tr(context, 'drive.disconnect'), onPressed: () => library.disconnectDrive()),
                ]
              : [
                  StaticTextButton(
                    label: tr(context, 'drive.connect'),
                    emphasize: true,
                    onPressed: library.driveBusy ? null : () => library.connectDrive(),
                  ),
                ],
        ),
      ],
    );
  }

  Widget _theme(LibraryController library, AppThemeKind kind, String name) {
    return StaticTextButton(
      label: name,
      selected: library.theme == kind,
      onPressed: () => library.setTheme(kind),
    );
  }
}
