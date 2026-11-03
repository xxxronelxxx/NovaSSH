import 'package:flutter/widgets.dart';

import 'palette.dart';

/// Active design tokens. `T.use(palette)` swaps the whole theme; widgets read
/// colours through getters so no `BuildContext` is required.
class T {
  static NovaPalette _p = darkPalette;

  static NovaPalette get palette => _p;
  static void use(NovaPalette p) => _p = p;

  static Brightness get brightness => _p.brightness;

  static Color get window => _p.window;
  static Color get toolbar => _p.toolbar;
  static Color get panel => _p.panel;
  static Color get menu => _p.menu;
  static Color get raised => _p.raised;
  static Color get border => _p.border;
  static Color get borderStrong => _p.borderStrong;

  static Color get text => _p.text;
  static Color get dim => _p.dim;
  static Color get faint => _p.faint;
  static Color get inverse => _p.inverse;

  static Color get accent => _p.accent;
  static Color get accentHover => _p.accentHover;
  static Color get accentPressed => _p.accentPressed;
  static Color get hover => _p.hover;
  static Color get selection => _p.selection;
  static Color get selectionInactive => _p.selectionInactive;

  static Color get success => _p.success;
  static Color get warn => _p.warn;
  static Color get error => _p.error;

  static Color get dir => _p.dir;
  static Color get symlink => _p.symlink;
  static Color get archive => _p.archive;
  static Color get exec => _p.exec;

  static Color get shellTop => _p.shellTop;
  static Color get shellBottom => _p.shellBottom;
  static Color get panelHeader => _p.panelHeader;
  static Color get panelSubtle => _p.panelSubtle;
  static Color get warnSurface => _p.warnSurface;

  // Geometry (theme-independent for now).
  static const double radius = 10.0;
  static const double radiusSmall = 6.0;
  static const double rowHeight = 26.0;
  static const double gap = 8.0;

  static const String uiFont = 'Inter';
  static const String monoFont = 'JetBrains Mono';
}
