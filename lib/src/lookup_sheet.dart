import 'dart:async';

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'lookup.dart';
import 'widgets.dart';

/// The bottom half of the reader while a word is looked up. The word, its Chinese,
/// the speak button, and close stay on top; everything else scrolls under them.
class LookupSheet extends StatefulWidget {
  const LookupSheet({required this.word, required this.onClose, required this.onSay, super.key});

  /// The word as it appears in the book.
  final String word;
  final VoidCallback onClose;
  final VoidCallback onSay;

  @override
  State<LookupSheet> createState() => _LookupSheetState();
}

class _LookupSheetState extends State<LookupSheet> {
  var _gen = 0;
  DictEntry? _entry;
  var _dictDone = false;
  OnlineLookup? _online;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(LookupSheet old) {
    super.didUpdateWidget(old);
    if (old.word != widget.word) unawaited(_load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String get _query => widget.word.replaceAll('\u2019', "'").replaceAll(RegExp(r"^[^A-Za-z]+|[^A-Za-z]+$|'s$"), '');

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() {
      _entry = null;
      _dictDone = false;
      _online = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    DictEntry? entry;
    try {
      entry = (await WordDictionary.load()).find(widget.word);
    } catch (_) {}
    if (!mounted || gen != _gen) return;
    setState(() {
      _entry = entry;
      _dictDone = true;
    });
    final online = await lookupOnline(_query, needWiki: entry == null || entry.chinese.isEmpty);
    if (!mounted || gen != _gen) return;
    setState(() => _online = online);
  }

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.paper,
        border: Border(top: BorderSide(color: colors.ink, width: 2)),
      ),
      child: DefaultTextStyle(
        style: TextStyle(color: colors.ink, fontSize: 15, height: 1.45),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(colors),
            Container(height: 1, color: colors.line),
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _body(colors),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Chinese first: the word list, then the Chinese Wikipedia title, then English.
  ({String text, bool chinese})? get _summary {
    final entry = _entry;
    if (entry != null && entry.chinese.isNotEmpty) return (text: entry.chinese, chinese: true);
    final online = _online;
    final zh = online?.chineseWiki;
    if (zh != null) return (text: zh.title, chinese: true);
    if (online != null && online.meanings.isNotEmpty) {
      return (text: online.meanings.first.senses.first.definition, chinese: false);
    }
    final en = online?.englishWiki;
    if (en != null) return (text: en.extract, chinese: false);
    return null;
  }

  Widget _header(AppColors colors) {
    final entry = _entry;
    final base = entry != null && entry.word != normalizeLookupWord(widget.word) ? entry.word : null;
    final summary = _summary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.end,
                  spacing: 10,
                  children: [
                    Text(_query, style: const TextStyle(fontSize: 24, height: 1.2, fontWeight: FontWeight.w600)),
                    if (base != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          tr(context, 'lookup.base_form', {'word': base}),
                          style: TextStyle(fontSize: 13, color: colors.muted),
                        ),
                      ),
                    if (entry != null && entry.level.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(entry.level, style: TextStyle(fontSize: 13, color: colors.muted)),
                      ),
                  ],
                ),
                if (summary != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    summary.text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: summary.chinese ? 16 : 14, height: 1.4),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          _IconBox(icon: Icons.volume_up, label: tr(context, 'lookup.say'), onPressed: widget.onSay),
          const SizedBox(width: 8),
          StaticTextButton(label: tr(context, 'common.close'), onPressed: widget.onClose),
        ],
      ),
    );
  }

  List<Widget> _body(AppColors colors) {
    final out = <Widget>[];
    Widget heading(String text) => Padding(
          padding: EdgeInsets.only(top: out.isEmpty ? 0 : 18, bottom: 6),
          child: Text(text, style: TextStyle(fontSize: 13, color: colors.muted)),
        );

    final entry = _entry;
    final senses = entry?.senses ?? const <String>[];
    if (senses.length > 1 || (entry?.chinese.length ?? 0) > 40) {
      out.add(heading(tr(context, 'lookup.chinese')));
      for (final sense in senses) {
        out.add(Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(sense, style: const TextStyle(fontSize: 16)),
        ));
      }
    }

    final online = _online;
    final zh = online?.chineseWiki;
    if (zh != null) {
      out.add(heading(tr(context, 'lookup.wiki')));
      out.add(Text(zh.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)));
      out.add(const SizedBox(height: 4));
      out.add(Text(zh.extract, style: const TextStyle(fontSize: 15)));
    }

    if (online != null && online.meanings.isNotEmpty) {
      out.add(heading(tr(context, 'lookup.english')));
      for (final meaning in online.meanings) {
        if (meaning.partOfSpeech.isNotEmpty) {
          out.add(Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Text(meaning.partOfSpeech, style: const TextStyle(fontStyle: FontStyle.italic)),
          ));
        }
        for (var i = 0; i < meaning.senses.length; i++) {
          final sense = meaning.senses[i];
          out.add(Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 24, child: Text('${i + 1}.')),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sense.definition),
                      if (sense.example != null)
                        Text(sense.example!, style: TextStyle(color: colors.muted, fontStyle: FontStyle.italic)),
                    ],
                  ),
                ),
              ],
            ),
          ));
        }
      }
    }

    final en = online?.englishWiki;
    if (en != null) {
      out.add(heading('${tr(context, 'lookup.wiki')} · ${en.title}'));
      out.add(Text(en.extract));
    }

    final String? status;
    if (!_dictDone || online == null) {
      status = tr(context, 'lookup.loading');
    } else if (online.failed) {
      status = tr(context, 'lookup.offline');
    } else if (out.isEmpty) {
      status = tr(context, 'lookup.none');
    } else {
      status = null;
    }
    if (status != null) {
      out.add(Padding(
        padding: EdgeInsets.only(top: out.isEmpty ? 0 : 18),
        child: Text(status, style: TextStyle(fontSize: 14, color: colors.muted)),
      ));
    }

    if (online != null && !online.failed || senses.isNotEmpty) {
      out.add(Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Text(
          [
            if (senses.isNotEmpty) tr(context, 'lookup.source_dict'),
            if (online != null && !online.failed) tr(context, 'lookup.source_online'),
          ].join('\n'),
          style: TextStyle(fontSize: 12, color: colors.muted),
        ),
      ));
    }
    return out;
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.paper,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(controlRadius),
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 22, color: colors.ink),
          ),
        ),
      ),
    );
  }
}
