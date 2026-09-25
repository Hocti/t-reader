import 'package:flutter/material.dart';

import 'page_paint.dart';

enum AppThemeKind { einkWhite, einkBlack, light, dark }

AppThemeKind themeKindFromName(String? name) {
  for (final kind in AppThemeKind.values) {
    if (kind.name == name) return kind;
  }
  return AppThemeKind.einkWhite;
}

class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.kind,
    required this.paper,
    required this.ink,
    required this.line,
    required this.muted,
    required this.fill,
    required this.onFill,
    required this.pageCss,
    required this.inkCss,
    required this.fillCss,
    required this.onFillCss,
  });

  final AppThemeKind kind;
  final Color paper;
  final Color ink;
  final Color line;
  final Color muted;
  final Color fill;
  final Color onFill;
  final String pageCss;
  final String inkCss;
  final String fillCss;
  final String onFillCss;

  static const einkWhite = AppColors(
    kind: AppThemeKind.einkWhite,
    paper: Color(0xFFFFFFFF),
    ink: Color(0xFF000000),
    line: Color(0xFF000000),
    muted: Color(0xFF000000),
    fill: Color(0xFF000000),
    onFill: Color(0xFFFFFFFF),
    pageCss: '#ffffff',
    inkCss: '#000000',
    fillCss: '#000000',
    onFillCss: '#ffffff',
  );

  static const einkBlack = AppColors(
    kind: AppThemeKind.einkBlack,
    paper: Color(0xFF000000),
    ink: Color(0xFFFFFFFF),
    line: Color(0xFFFFFFFF),
    muted: Color(0xFFFFFFFF),
    fill: Color(0xFFFFFFFF),
    onFill: Color(0xFF000000),
    pageCss: '#000000',
    inkCss: '#ffffff',
    fillCss: '#ffffff',
    onFillCss: '#000000',
  );

  /// Warm paper and a muted green. A little color, still high contrast.
  static const light = AppColors(
    kind: AppThemeKind.light,
    paper: Color(0xFFF6F1E7),
    ink: Color(0xFF1C2430),
    line: Color(0xFFC4B49A),
    muted: Color(0xFF3E4C59),
    fill: Color(0xFF1F6B5A),
    onFill: Color(0xFFFFFFFF),
    pageCss: '#f6f1e7',
    inkCss: '#1c2430',
    fillCss: '#1f6b5a',
    onFillCss: '#ffffff',
  );

  /// Blue-black paper and a gold mark. A little color, still high contrast.
  static const dark = AppColors(
    kind: AppThemeKind.dark,
    paper: Color(0xFF1A2330),
    ink: Color(0xFFE6EDF4),
    line: Color(0xFF3D4E63),
    muted: Color(0xFFC5D0DC),
    fill: Color(0xFFD2A24C),
    onFill: Color(0xFF1A2330),
    pageCss: '#1a2330',
    inkCss: '#e6edf4',
    fillCss: '#d2a24c',
    onFillCss: '#1a2330',
  );

  PagePaint get paint => PagePaint(
        page: pageCss,
        ink: inkCss,
        accent: fillCss,
        onAccent: onFillCss,
        word: switch (kind) {
          AppThemeKind.light => '#e0a526',
          AppThemeKind.dark => '#7fb8e6',
          _ => null,
        },
        onWord: switch (kind) {
          AppThemeKind.light => '#1c2430',
          AppThemeKind.dark => '#1a2330',
          _ => null,
        },
      );

  static AppColors of(AppThemeKind kind) {
    switch (kind) {
      case AppThemeKind.einkWhite:
        return einkWhite;
      case AppThemeKind.einkBlack:
        return einkBlack;
      case AppThemeKind.light:
        return light;
      case AppThemeKind.dark:
        return dark;
    }
  }

  @override
  AppColors copyWith({
    AppThemeKind? kind,
    Color? paper,
    Color? ink,
    Color? line,
    Color? muted,
    Color? fill,
    Color? onFill,
    String? pageCss,
    String? inkCss,
    String? fillCss,
    String? onFillCss,
  }) {
    return AppColors(
      kind: kind ?? this.kind,
      paper: paper ?? this.paper,
      ink: ink ?? this.ink,
      line: line ?? this.line,
      muted: muted ?? this.muted,
      fill: fill ?? this.fill,
      onFill: onFill ?? this.onFill,
      pageCss: pageCss ?? this.pageCss,
      inkCss: inkCss ?? this.inkCss,
      fillCss: fillCss ?? this.fillCss,
      onFillCss: onFillCss ?? this.onFillCss,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors || t < 0.5) return this;
    return other;
  }
}

ThemeData themeFor(AppThemeKind kind) {
  final colors = AppColors.of(kind);
  final brightness = colors.ink.computeLuminance() > 0.5 ? Brightness.dark : Brightness.light;
  final typography = brightness == Brightness.dark
      ? Typography.material2021(platform: TargetPlatform.android).white
      : Typography.material2021(platform: TargetPlatform.android).black;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: colors.paper,
    canvasColor: colors.paper,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    dividerColor: colors.line,
    iconTheme: IconThemeData(color: colors.ink),
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: colors.fill,
      onPrimary: colors.onFill,
      secondary: colors.fill,
      onSecondary: colors.onFill,
      error: colors.ink,
      onError: colors.paper,
      surface: colors.paper,
      onSurface: colors.ink,
    ),
    textTheme: typography.apply(
      bodyColor: colors.ink,
      displayColor: colors.ink,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.paper,
      foregroundColor: colors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: colors.paper,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _NoAnimationTransitions(),
        TargetPlatform.iOS: _NoAnimationTransitions(),
        TargetPlatform.linux: _NoAnimationTransitions(),
        TargetPlatform.macOS: _NoAnimationTransitions(),
        TargetPlatform.windows: _NoAnimationTransitions(),
        TargetPlatform.fuchsia: _NoAnimationTransitions(),
      },
    ),
    extensions: [colors],
  );
}

class _NoAnimationTransitions extends PageTransitionsBuilder {
  const _NoAnimationTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

class StillScrollBehavior extends MaterialScrollBehavior {
  const StillScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

AppColors colorsOf(BuildContext context) {
  return Theme.of(context).extension<AppColors>() ?? AppColors.einkWhite;
}
