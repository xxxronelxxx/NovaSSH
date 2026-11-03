import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData buildNovaTheme() {
  final palette = T.palette;
  final base = ThemeData(
    brightness: palette.brightness,
    useMaterial3: true,
    fontFamily: T.uiFont,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: T.panel,
  );

  return base.copyWith(
    colorScheme: ColorScheme(
      brightness: palette.brightness,
      primary: T.accent,
      onPrimary: Colors.white,
      secondary: T.accent,
      onSecondary: Colors.white,
      surface: T.panel,
      onSurface: T.text,
      error: T.error,
      onError: Colors.white,
    ),
    dividerColor: T.border,
    splashFactory: InkSparkle.splashFactory,
    textTheme: base.textTheme.apply(bodyColor: T.text, displayColor: T.text),
    tooltipTheme: TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: T.menu,
        borderRadius: BorderRadius.all(Radius.circular(T.radiusSmall)),
        border: Border.all(color: T.border),
      ),
      textStyle: TextStyle(color: T.text, fontSize: 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: T.menu,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        side: BorderSide(color: T.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.brightness == Brightness.dark
          ? Color(0x66000000)
          : Color(0x66FFFFFF),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(T.radiusSmall),
        borderSide: BorderSide(color: T.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(T.radiusSmall),
        borderSide: BorderSide(color: T.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(T.radiusSmall),
        borderSide: BorderSide(color: T.accent),
      ),
      hintStyle: TextStyle(color: T.faint, fontSize: 13),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(9),
      radius: const Radius.circular(9),
      thumbColor: WidgetStateProperty.all(
        palette.brightness == Brightness.dark
            ? Color(0x33FFFFFF)
            : Color(0x33000000),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(color: T.menu),
    // Without an explicit contentTextStyle Material 3 uses
    // `onInverseSurface`, which is white in light mode -> white on white.
    snackBarTheme: SnackBarThemeData(
      backgroundColor: T.raised,
      contentTextStyle: TextStyle(color: T.text, fontSize: 12.5),
      actionTextColor: T.accent,
      behavior: SnackBarBehavior.floating,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: T.border),
      ),
    ),
  );
}
