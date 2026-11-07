import 'package:flutter/material.dart';

import '../bridge/model.dart';
import 'tokens.dart';

/// WinSCP-like colours: folders are warm yellow, archives purple, scripts
/// green, images green-blue and so on. They stay readable on both themes.
class _C {
  static const folder = Color(0xFFF0C04A);
  static const archive = Color(0xFFC08CFF);
  static const image = Color(0xFF5FD68A);
  static const video = Color(0xFFF07A9B);
  static const audio = Color(0xFFE0A4F5);
  static const code = Color(0xFF6CB6FF);
  static const script = Color(0xFF8BE28B);
  static const text = Color(0xFFB9C2CF);
  static const config = Color(0xFFD7B36A);
  static const pdf = Color(0xFFF27D72);
  static const database = Color(0xFF63C7C9);
  static const font = Color(0xFF9BB7E8);
  static const sheet = Color(0xFF7FCF9B);
  static const binary = Color(0xFFA8B0BD);
}

class FileVisual {
  const FileVisual(this.icon, this.color, {this.link = false});

  final IconData icon;
  final Color color;

  /// Draws a small arrow badge in the corner.
  final bool link;
}

const _archives = {
  'zip', 'tar', 'gz', 'tgz', 'tbz2', 'tbz', 'txz', 'tzst', 'bz2', 'xz', //
  'zst', '7z', 'rar', 'deb', 'rpm', 'iso', 'cab', 'arj', 'lha', 'jar',
  'war', 'apk', 'ipa', 'dmg', 'pkg',
};
const _images = {
  'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'svg', 'ico', 'tif', 'tiff', //
  'avif', 'heic', 'heif', 'psd', 'ai', 'eps', 'raw', 'cr2', 'nef',
};
const _video = {
  'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'm4v', 'mpg', 'mpeg', //
  '3gp', 'ogv',
};
const _audio = {
  'mp3', 'ogg', 'wav', 'flac', 'aac', 'm4a', 'opus', 'wma', 'mid', 'midi',
};
const _code = {
  'php', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'json', 'html', 'htm', //
  'xhtml', 'css', 'scss', 'sass', 'less', 'dart', 'rs', 'go', 'py', 'rb',
  'java', 'kt', 'kts', 'c', 'h', 'cpp', 'cc', 'cxx', 'hpp', 'cs', 'swift',
  'm', 'mm', 'vue', 'svelte', 'xml', 'yml', 'yaml', 'toml', 'sql', 'graphql',
  'proto', 'gradle', 'lua', 'pl', 'r', 'scala', 'clj', 'ex', 'exs', 'erl',
  'hs', 'twig', 'blade', 'tmpl',
};
const _scripts = {'sh', 'bash', 'zsh', 'fish', 'bat', 'cmd', 'ps1', 'psm1', 'vbs'};
const _text = {'txt', 'md', 'markdown', 'rst', 'log', 'rtf', 'doc', 'docx', 'odt', 'tex'};
const _config = {
  'ini', 'conf', 'cfg', 'env', 'properties', 'htaccess', 'gitignore', //
  'dockerignore', 'editorconfig', 'npmrc', 'htpasswd', 'yml', 'yaml',
  'toml', 'cnf', 'service', 'rules',
};
const _pdf = {'pdf'};
const _database = {'db', 'sqlite', 'sqlite3', 'mdb', 'accdb', 'dbf'};
const _sheets = {'xls', 'xlsx', 'ods', 'csv', 'tsv'};
const _fonts = {'ttf', 'otf', 'woff', 'woff2', 'eot'};
const _binary = {
  'exe', 'msi', 'com', 'bin', 'so', 'dll', 'dylib', 'a', 'o', 'lib', //
  'obj', 'class', 'pyc', 'wasm',
};

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// Chooses the icon and colour for one entry.
FileVisual visualFor(Entry entry) {
  final name = entry.name;
  final lower = name.toLowerCase();
  final isDir = entry.kind == EntryKind.dir;
  final isLink = entry.kind == EntryKind.symlink || entry.linkTarget != null;
  final folderIcon =
      T.folderIcons == 'outline' ? Icons.folder_outlined : Icons.folder_rounded;

  if (!T.coloredIcons) {
    if (isDir) return FileVisual(folderIcon, T.dir, link: isLink);
    if (isLink) return FileVisual(Icons.link, T.symlink, link: true);
    if (_archives.contains(_extension(name))) {
      return FileVisual(Icons.folder_zip_outlined, T.archive, link: isLink);
    }
    return FileVisual(Icons.insert_drive_file_outlined, T.faint, link: isLink);
  }

  if (isDir) return FileVisual(folderIcon, _C.folder, link: isLink);

  final ext = _extension(name);
  FileVisual make(IconData icon, Color color) =>
      FileVisual(icon, color, link: isLink);

  if (_archives.contains(ext)) {
    return make(Icons.folder_zip_outlined, _C.archive);
  }
  if (_images.contains(ext)) return make(Icons.image_outlined, _C.image);
  if (_video.contains(ext)) return make(Icons.movie_outlined, _C.video);
  if (_audio.contains(ext)) return make(Icons.audiotrack, _C.audio);
  if (_pdf.contains(ext)) {
    return make(Icons.picture_as_pdf_outlined, _C.pdf);
  }
  if (_database.contains(ext)) return make(Icons.storage, _C.database);
  if (_sheets.contains(ext)) {
    return make(Icons.table_chart_outlined, _C.sheet);
  }
  if (_fonts.contains(ext)) return make(Icons.text_fields, _C.font);
  if (_scripts.contains(ext)) return make(Icons.terminal, _C.script);
  if (_code.contains(ext)) return make(Icons.code, _C.code);
  if (_config.contains(ext)) return make(Icons.settings_outlined, _C.config);
  if (_text.contains(ext)) {
    return make(Icons.description_outlined, _C.text);
  }
  if (_binary.contains(ext)) return make(Icons.memory, _C.binary);

  // Well-known files without an extension.
  if (lower == 'dockerfile' || lower == 'makefile' || lower == 'cmakelists.txt') {
    return make(Icons.settings_outlined, _C.config);
  }
  if (lower.startsWith('readme') || lower.startsWith('license')) {
    return make(Icons.description_outlined, _C.text);
  }

  // A plain executable has no extension: the +x bit still tells us.
  final executable = entry.mode != null && (entry.mode! & 0x49) != 0;
  if (executable) return make(Icons.terminal, _C.script);

  return make(Icons.insert_drive_file_outlined, _C.binary);
}

/// Row icon with an optional shortcut arrow for symlinks.
class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon({super.key, required this.entry, this.size = 15});

  final Entry entry;
  final double size;

  @override
  Widget build(BuildContext context) {
    final visual = visualFor(entry);
    if (!visual.link) {
      return Icon(visual.icon, size: size, color: visual.color);
    }
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(visual.icon, size: size, color: visual.color),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(0.5),
              decoration: BoxDecoration(
                color: T.fileSurface,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.north_east,
                size: size * 0.45,
                color: visual.color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
