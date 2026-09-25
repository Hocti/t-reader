import 'package:flutter/material.dart';

import 'i18n.dart';
import 'theme.dart';

export 'theme.dart';

const controlRadius = 8.0;

Future<T?> pushPage<T>(BuildContext context, Widget page) {
  return Navigator.of(context).push<T>(stillRoute<T>(page));
}

/// A route with no transition.
Route<T> stillRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) => child,
  );
}

class StaticTextButton extends StatelessWidget {
  const StaticTextButton({
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.emphasize = false,
    this.expand = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final bool emphasize;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    final enabled = onPressed != null;
    final filled = enabled && (selected || emphasize);
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: filled ? colors.fill : colors.paper,
            border: Border.all(color: enabled ? colors.line : colors.muted),
            borderRadius: BorderRadius.circular(controlRadius),
          ),
          child: SizedBox(
            width: expand ? double.infinity : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: filled ? colors.onFill : (enabled ? colors.ink : colors.muted),
                  fontSize: 13,
                  height: 1.3,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class StaticProgressBar extends StatelessWidget {
  const StaticProgressBar({required this.value, this.label, super.key});

  final double value;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    final fraction = value.clamp(0.0, 1.0);
    return Semantics(
      label: label == null ? tr(context, 'shelf.progress') : tr(context, 'shelf.progress_value', {'label': label!}),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.paper,
          border: Border.all(color: colors.ink),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: constraints.maxWidth * fraction,
                  height: 8,
                  child: ColoredBox(color: colors.fill),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class BackLabel extends StatelessWidget {
  const BackLabel({super.key});

  @override
  Widget build(BuildContext context) {
    return StaticTextButton(
      label: tr(context, 'common.back'),
      onPressed: () => Navigator.of(context).maybePop(),
    );
  }
}

class ChoiceOption {
  const ChoiceOption({required this.label, required this.selected, required this.onPressed});

  final String label;
  final bool selected;
  final VoidCallback onPressed;
}

/// One labeled group of choices. The selected item is filled, with no extra status word.
class ChoiceGroup extends StatelessWidget {
  const ChoiceGroup({required this.caption, required this.options, super.key});

  final String caption;
  final List<ChoiceOption> options;

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(caption, style: TextStyle(fontSize: 12, height: 1.2, color: colors.muted)),
        const SizedBox(height: 4),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(controlRadius),
          ),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Wrap(
              spacing: 2,
              runSpacing: 2,
              children: [
                for (final option in options)
                  Semantics(
                    button: true,
                    selected: option.selected,
                    label: option.label,
                    child: GestureDetector(
                      onTap: option.onPressed,
                      behavior: HitTestBehavior.opaque,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: option.selected ? colors.fill : colors.paper,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          child: Text(
                            option.label,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.2,
                              color: option.selected ? colors.onFill : colors.ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class IconChoice {
  const IconChoice({required this.icon, required this.label, required this.selected, required this.onPressed});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;
}

/// Icons in one bordered group. The label is for screen readers; the selected icon is filled.
class IconChoiceGroup extends StatelessWidget {
  const IconChoiceGroup({required this.options, super.key});

  final List<IconChoice> options;

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(controlRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              Semantics(
                button: true,
                selected: option.selected,
                label: option.label,
                excludeSemantics: true,
                child: GestureDetector(
                  onTap: option.onPressed,
                  behavior: HitTestBehavior.opaque,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: option.selected ? colors.fill : colors.paper,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Icon(option.icon, size: 20, color: option.selected ? colors.onFill : colors.ink),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
