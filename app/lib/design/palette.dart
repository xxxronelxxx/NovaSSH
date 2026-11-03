import 'package:flutter/material.dart';

/// Colour tokens for one concrete theme. `T` exposes the active palette through
/// getters, so switching themes only requires swapping the palette and rebuilding.
class NovaPalette {
  const NovaPalette({
    required this.brightness,
    required this.window,
    required this.toolbar,
    required this.panel,
    required this.menu,
    required this.raised,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.dim,
    required this.faint,
    required this.inverse,
    required this.accent,
    required this.accentHover,
    required this.accentPressed,
    required this.hover,
    required this.selection,
    required this.selectionInactive,
    required this.success,
    required this.warn,
    required this.error,
    required this.dir,
    required this.symlink,
    required this.archive,
    required this.exec,
    required this.shellTop,
    required this.shellBottom,
    required this.panelHeader,
    required this.panelSubtle,
    required this.warnSurface,
  });

  final Brightness brightness;
  final Color window;
  final Color toolbar;
  final Color panel;
  final Color menu;
  final Color raised;
  final Color border;
  final Color borderStrong;
  final Color text;
  final Color dim;
  final Color faint;
  final Color inverse;
  final Color accent;
  final Color accentHover;
  final Color accentPressed;
  final Color hover;
  final Color selection;
  final Color selectionInactive;
  final Color success;
  final Color warn;
  final Color error;
  final Color dir;
  final Color symlink;
  final Color archive;
  final Color exec;
  final Color shellTop;
  final Color shellBottom;
  final Color panelHeader;
  final Color panelSubtle;
  final Color warnSurface;
}

const darkPalette = NovaPalette(
  brightness: Brightness.dark,
  window: Color(0x000F1115),
  toolbar: Color(0xB8151922),
  panel: Color(0xF0141820),
  menu: Color(0xF0181D26),
  raised: Color(0xFF1B2029),
  border: Color(0x14FFFFFF),
  borderStrong: Color(0x26FFFFFF),
  text: Color(0xFFE8ECF3),
  dim: Color(0xFF9AA4B2),
  faint: Color(0xFF6B7480),
  inverse: Color(0xFF0B0D12),
  accent: Color(0xFF4C8DFF),
  accentHover: Color(0xFF6BA1FF),
  accentPressed: Color(0xFF3A73D9),
  hover: Color(0x0DFFFFFF),
  selection: Color(0x384C8DFF),
  selectionInactive: Color(0x14FFFFFF),
  success: Color(0xFF3FB950),
  warn: Color(0xFFD29922),
  error: Color(0xFFF85149),
  dir: Color(0xFF7FB4FF),
  symlink: Color(0xFF56D4DD),
  archive: Color(0xFFC39BFF),
  exec: Color(0xFF8BE28B),
  shellTop: Color(0xC20F1115),
  shellBottom: Color(0xE60A0C10),
  panelHeader: Color(0x4D0B0D12),
  panelSubtle: Color(0x33000000),
  warnSurface: Color(0xFF3A2A12),
);

const lightPalette = NovaPalette(
  brightness: Brightness.light,
  window: Color(0x00F4F6FA),
  toolbar: Color(0xD9EEF1F6),
  panel: Color(0xF7FFFFFF),
  menu: Color(0xFAFFFFFF),
  raised: Color(0xFFFFFFFF),
  border: Color(0x14000000),
  borderStrong: Color(0x24000000),
  text: Color(0xFF141922),
  dim: Color(0xFF5A6473),
  faint: Color(0xFF8A93A2),
  inverse: Color(0xFFFFFFFF),
  accent: Color(0xFF2F6FEB),
  accentHover: Color(0xFF4A83F0),
  accentPressed: Color(0xFF255BC4),
  hover: Color(0x0A000000),
  selection: Color(0x2E2F6FEB),
  selectionInactive: Color(0x0F000000),
  success: Color(0xFF1F7A34),
  warn: Color(0xFF9A6B06),
  error: Color(0xFFC62828),
  dir: Color(0xFF1D5FD6),
  symlink: Color(0xFF0E8F9E),
  archive: Color(0xFF7B4FD1),
  exec: Color(0xFF1F7A34),
  shellTop: Color(0xD9F4F6FA),
  shellBottom: Color(0xF2EDF1F7),
  panelHeader: Color(0x0F000000),
  panelSubtle: Color(0x0A000000),
  warnSurface: Color(0xFFFFF4E0),
);
