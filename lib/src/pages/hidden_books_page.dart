import 'package:flutter/material.dart';

import '../i18n.dart';
import '../library_scope.dart';
import '../widgets.dart';

/// Hidden books, one by one. Opened from the count on the settings page.
class HiddenBooksPage extends StatelessWidget {
  const HiddenBooksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final colors = colorsOf(context);
    final hidden = library.hiddenBooks;
    return Scaffold(
      backgroundColor: colors.paper,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Align(alignment: Alignment.centerLeft, child: BackLabel()),
            const SizedBox(height: 16),
            Text(tr(context, 'settings.hidden'), style: const TextStyle(fontSize: 22, height: 1.2)),
            const SizedBox(height: 20),
            if (hidden.isEmpty)
              Text(tr(context, 'settings.none_hidden'), style: const TextStyle(fontSize: 14))
            else
              for (final book in hidden) ...[
                Text(book.title, style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 4),
                SelectableText(book.path, style: TextStyle(fontSize: 14, color: colors.muted)),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: StaticTextButton(
                    label: tr(context, 'settings.restore'),
                    onPressed: () => library.setHidden(book.path, false),
                  ),
                ),
                const SizedBox(height: 16),
              ],
          ],
        ),
      ),
    );
  }
}
