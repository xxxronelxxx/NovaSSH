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

  // -------------------------------------------------------------------------
  // Appearance (Settings → «Внешний вид»)
  // -------------------------------------------------------------------------

  /// `colored` (by file type, WinSCP-like) or `mono`.
  static String _fileIcons = 'colored';
  /// `filled` or `outline`.
  static String _folderIcons = 'filled';
  static String _uiFont = 'Inter';
  static String _monoFont = 'JetBrains Mono';
  static double _fileFontSize = 12;
  static Color? _fileText;
  static Color? _fileSurface;

  static String get fileIcons => _fileIcons;
  static String get folderIcons => _folderIcons;
  static String get uiFont => _uiFont;
  static String get monoFont => _monoFont;
  static double get fileFontSize => _fileFontSize;
  static bool get coloredIcons => _fileIcons == 'colored';

  /// Text colour inside file panes; `null` means "use the theme".
  static Color? get fileTextOverride => _fileText;
  static Color? get fileSurfaceOverride => _fileSurface;

  static Color get fileText => _fileText ?? _p.text;
  static Color get dirText => _fileText ?? _p.dir;
  static Color get linkText => _fileText ?? _p.symlink;
  static Color get otherText => _fileText ?? _p.faint;
  /// Pane background, honouring the override (also used behind link badges).
  static Color get fileSurface => _fileSurface ?? _p.panel;

  static void useAppearance({
    required String fileIcons,
    required String folderIcons,
    required String uiFont,
    required String monoFont,
    required int panelFontSize,
    required String panelText,
    required String panelBackground,
  }) {
    _fileIcons = fileIcons == 'mono' ? 'mono' : 'colored';
    _folderIcons = folderIcons == 'outline' ? 'outline' : 'filled';
    _uiFont = uiFont.trim().isEmpty ? 'Inter' : uiFont.trim();
    _monoFont = monoFont.trim().isEmpty ? 'JetBrains Mono' : monoFont.trim();
    _fileFontSize = panelFontSize.clamp(10, 16).toDouble();
    _fileText = _parseColor(panelText);
    _fileSurface = _parseColor(panelBackground);
  }

  static Color? _parseColor(String value) {
    final hex = value.trim().replaceFirst('#', '');
    if (hex.length != 6) return null;
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return null;
    return Color(0xFF000000 | parsed);
  }

  // Geometry.
  static const double radius = 10.0;
  static const double radiusSmall = 6.0;

  /// Rows grow with the panel font so larger text is not clipped.
  static double get rowHeight => (_fileFontSize + 14).clamp(26.0, 33.0);

  static const double gap = 8.0;
}
