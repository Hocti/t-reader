import 'package:flutter/material.dart';

import '../i18n.dart';
import '../library.dart';
import '../library_scope.dart';
import '../widgets.dart';
import 'reader_page.dart';
import 'settings_page.dart';

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> with WidgetsBindingObserver {
  final _searchField = TextEditingController();

  /// Null while the search row is closed.
  String? _query;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchField.dispose();
    super.dispose();
  }

  void _closeSearch() {
    _searchField.clear();
    setState(() => _query = null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      LibraryScope.of(context).rescan();
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = LibraryScope.of(context);
    final colors = colorsOf(context);
    final shelf = library.visibleBooks;
    final query = _query?.trim() ?? '';
    final visible = query.isEmpty ? shelf : filterBooks(shelf, query);
    final message = emptyShelfNotice(
      directories: library.directories.length,
      books: library.books.length,
      visible: shelf.length,
      missing: library.missing.length,
      unreadable: library.unreadable.length,
      filter: library.filter,
    );

    final page = Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _shelf(context, library, colors, shelf, visible, query, message)),
          Positioned(
            left: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _SearchButton(
                  open: _query != null,
                  onPressed: () => _query == null ? setState(() => _query = '') : _closeSearch(),
                ),
              ),
            ),
          ),
        ],
      ),
      backgroundColor: colors.paper,
    );
    return PopScope(
      canPop: _query == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeSearch();
      },
      child: page,
    );
  }

  Widget _shelf(
    BuildContext context,
    LibraryController library,
    AppColors colors,
    List<ShelfBook> shelf,
    List<ShelfBook> visible,
    String query,
    ShelfNotice? message,
  ) {
    return SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 2, 8),
              child: Row(
                children: [
                  IconChoiceGroup(
                    options: [
                      IconChoice(
                        icon: Icons.view_list_outlined,
                        label: tr(context, 'shelf.list'),
                        selected: library.view == ShelfView.list,
                        onPressed: () => library.setView(ShelfView.list),
                      ),
                      IconChoice(
                        icon: Icons.grid_view,
                        label: tr(context, 'shelf.grid'),
                        selected: library.view == ShelfView.grid,
                        onPressed: () => library.setView(ShelfView.grid),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  IconChoiceGroup(
                    options: [
                      IconChoice(
                        icon: Icons.history,
                        label: tr(context, 'shelf.sort_recent'),
                        selected: library.sort == ShelfSort.lastRead,
                        onPressed: () => library.setSort(ShelfSort.lastRead),
                      ),
                      IconChoice(
                        icon: Icons.sort_by_alpha,
                        label: tr(context, 'shelf.sort_title'),
                        selected: library.sort == ShelfSort.title,
                        onPressed: () => library.setSort(ShelfSort.title),
                      ),
                      IconChoice(
                        icon: Icons.percent,
                        label: tr(context, 'shelf.sort_progress'),
                        selected: library.sort == ShelfSort.progress,
                        onPressed: () => library.setSort(ShelfSort.progress),
                      ),
                      // Sorting by the file's modified (added) date is off for now, to keep the row short.
                      // IconChoice(
                      //   icon: Icons.update,
                      //   label: tr(context, 'shelf.sort_modified'),
                      //   selected: library.sort == ShelfSort.modified,
                      //   onPressed: () => library.setSort(ShelfSort.modified),
                      // ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  _FilterButton(library: library),
                  const Spacer(),
                  Semantics(
                    button: true,
                    label: tr(context, 'common.settings'),
                    child: GestureDetector(
                      onTap: () => pushPage(context, const SettingsPage()),
                      behavior: HitTestBehavior.opaque,
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.settings_outlined, size: 22),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_query != null) _searchRow(colors),
            Expanded(
              child: query.isNotEmpty && visible.isEmpty && shelf.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        tr(context, 'shelf.search_none', {'query': query}),
                        style: const TextStyle(fontSize: 16, height: 1.4),
                      ),
                    )
                  : visible.isEmpty
                  ? _EmptyShelf(message: message, library: library)
                  : Column(
                      children: [
                        for (final path in library.missing) _DirNote(keyName: 'shelf.dir_missing', path: path),
                        for (final path in library.unreadable)
                          _DirNote(keyName: 'shelf.dir_unreadable', path: path),
                        Expanded(
                          child: library.view == ShelfView.grid
                              ? _BookGrid(books: visible)
                              : _BookList(books: visible),
                        ),
                      ],
                    ),
            ),
          ],
        ),
    );
  }

  Widget _searchRow(AppColors colors) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(controlRadius),
      borderSide: BorderSide(color: colors.line),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchField,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
              cursorColor: colors.ink,
              style: TextStyle(color: colors.ink, fontSize: 16),
              decoration: InputDecoration(
                isDense: true,
                hintText: tr(context, 'shelf.search_hint'),
                hintStyle: TextStyle(color: colors.muted),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: border,
                enabledBorder: border,
                focusedBorder: border,
              ),
            ),
          ),
          const SizedBox(width: 8),
          StaticTextButton(label: tr(context, 'common.close'), onPressed: _closeSearch),
        ],
      ),
    );
  }
}

const _filterKeys = {
  ShelfFilter.shelf: 'shelf.filter_shelf',
  ShelfFilter.reading: 'shelf.filter_reading',
  ShelfFilter.unstarted: 'shelf.filter_unstarted',
  ShelfFilter.finished: 'shelf.filter_finished',
  ShelfFilter.archived: 'shelf.filter_archived',
  ShelfFilter.all: 'shelf.filter_all',
};

/// Round, bottom left. Opens the search row, or closes it when it is open.
class _SearchButton extends StatelessWidget {
  const _SearchButton({required this.open, required this.onPressed});

  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    return Semantics(
      button: true,
      selected: open,
      label: tr(context, 'shelf.search'),
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: open ? colors.fill : colors.paper,
            border: Border.all(color: colors.ink),
            shape: BoxShape.circle,
          ),
          child: SizedBox(
            width: _searchButtonSize,
            height: _searchButtonSize,
            child: Icon(open ? Icons.search_off : Icons.search, size: 24, color: open ? colors.onFill : colors.ink),
          ),
        ),
      ),
    );
  }
}

const _searchButtonSize = 52.0;

/// Room under the last book so the search button does not cover it.
const _shelfBottomRoom = _searchButtonSize + 32;

/// An icon only; filled when the filter is not the default. A tap opens the list of filters.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.library});

  final LibraryController library;

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    final active = library.filter != ShelfFilter.shelf;
    final label = tr(context, _filterKeys[library.filter]!);
    return Semantics(
      button: true,
      label: tr(context, 'shelf.filter_label', {'filter': label}),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openFilterMenu(context, library),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: active ? colors.fill : colors.paper,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(controlRadius),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.filter_list, size: 20, color: active ? colors.onFill : colors.ink),
          ),
        ),
      ),
    );
  }
}

Future<void> _openFilterMenu(BuildContext context, LibraryController library) {
  final colors = colorsOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: tr(context, 'common.close'),
    barrierColor: const Color(0x66000000),
    transitionDuration: Duration.zero,
    transitionBuilder: (context, animation, secondaryAnimation, child) => child,
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.paper,
                border: Border.all(color: colors.ink),
                borderRadius: BorderRadius.circular(controlRadius),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in _filterKeys.entries) ...[
                      StaticTextButton(
                        label: tr(context, entry.value),
                        expand: true,
                        selected: library.filter == entry.key,
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          library.setFilter(entry.key);
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                    StaticTextButton(
                      label: tr(context, 'common.close'),
                      expand: true,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _DirNote extends StatelessWidget {
  const _DirNote({required this.keyName, required this.path});

  final String keyName;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(tr(context, keyName, {'path': path}), style: const TextStyle(fontSize: 14)),
      ),
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf({required this.message, required this.library});

  final ShelfNotice? message;
  final LibraryController library;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final path in library.missing) ...[
          Text(tr(context, 'shelf.dir_missing', {'path': path}), style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
        ],
        for (final path in library.unreadable) ...[
          Text(tr(context, 'shelf.dir_unreadable', {'path': path}), style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
        ],
        if (message != null)
          Text(tr(context, message!.key), style: const TextStyle(fontSize: 16, height: 1.4)),
      ],
    );
  }
}

class _BookList extends StatelessWidget {
  const _BookList({required this.books});

  final List<ShelfBook> books;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, _shelfBottomRoom),
      children: [
        for (final book in books) ...[
          BookCard(book: book),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _BookGrid extends StatelessWidget {
  const _BookGrid({required this.books});

  final List<ShelfBook> books;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900 ? 3 : 2;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, _shelfBottomRoom),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: 280,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: books.length,
          itemBuilder: (context, index) => BookCard(book: books[index], grid: true),
        );
      },
    );
  }
}

class BookCard extends StatelessWidget {
  const BookCard({required this.book, this.grid = false, super.key});

  final ShelfBook book;
  final bool grid;

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    final progress = progressLabel(book);
    final when = formatReadTime(book.lastRead) ?? tr(context, 'shelf.unread');
    final size = grid ? 14.0 : 16.0;
    final details = <Widget>[
      // Two lines of room even for a short title, so every cover above is the same height.
      SizedBox(
        height: grid ? size * 1.3 * 2 + 2 : null,
        child: Text(
          book.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: size, height: 1.3),
        ),
      ),
      const SizedBox(height: 4),
      Text(when, maxLines: 1, style: TextStyle(color: colors.muted, fontSize: 12)),
      const SizedBox(height: 8),
      StaticProgressBar(value: book.progress, label: progress),
    ];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => pushPage(context, ReaderPage(path: book.path)),
      onLongPress: () => _openBookMenu(context, book),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: grid
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _Cover(book: book)),
                  const SizedBox(height: 8),
                  ...details,
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: _listCoverWidth, height: _listCoverHeight, child: _Cover(book: book, crop: true)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: details),
                  ),
                ],
              ),
      ),
    );
  }
}

const _listCoverWidth = 48.0;
const _listCoverHeight = 72.0;

/// Fills the cover's height. A wide cover is cut at the sides. [crop] fills the whole box instead.
class _Cover extends StatelessWidget {
  const _Cover({required this.book, this.crop = false});

  final ShelfBook book;
  final bool crop;

  @override
  Widget build(BuildContext context) {
    final bytes = book.cover;
    if (bytes == null) return const SizedBox.expand();
    return ClipRect(
      child: Image.memory(
        bytes,
        fit: crop ? BoxFit.cover : BoxFit.fitHeight,
        alignment: Alignment.center,
        gaplessPlayback: true,
      ),
    );
  }
}

Future<void> _openBookMenu(BuildContext context, ShelfBook book) {
  final library = LibraryScope.of(context);
  final colors = colorsOf(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: tr(context, 'common.close'),
    barrierColor: const Color(0x66000000),
    transitionDuration: Duration.zero,
    transitionBuilder: (context, animation, secondaryAnimation, child) => child,
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.paper,
                border: Border.all(color: colors.ink),
                borderRadius: BorderRadius.circular(controlRadius),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    StaticTextButton(
                      label: book.archived ? tr(context, 'shelf.unarchive') : tr(context, 'shelf.archive'),
                      expand: true,
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        library.setArchived(book.path, !book.archived);
                      },
                    ),
                    const SizedBox(height: 8),
                    StaticTextButton(
                      label: tr(context, 'shelf.hide'),
                      expand: true,
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        library.setHidden(book.path, true);
                      },
                    ),
                    const SizedBox(height: 8),
                    StaticTextButton(
                      label: tr(context, 'common.close'),
                      expand: true,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
