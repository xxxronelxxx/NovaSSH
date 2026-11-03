import 'dart:math' as math;

/// One line of the multi-rename preview.
typedef RenameRow = ({String from, String to, String? problem});

/// Total Commander style multi-rename masks.
///
/// Supported tokens: `[N]` name without extension, `[E]` extension without the
/// dot, `[C]` counter, `[Y]`/`[M]`/`[D]` date parts, `[h]`/`[m]`/`[s]` time
/// parts. `[N]` and `[E]` keep their original text, the counter is padded to
/// the width needed by the number of files. A mask without `[E]` keeps the
/// original extension.
String applyRenameMask(
  String mask, {
  required String name,
  required String ext,
  required int index,
  required int total,
  DateTime? now,
}) {
  final stamp = now ?? DateTime.now();
  final digits = math.max(1, total.toString().length);
  final counter = (index + 1).toString().padLeft(digits, '0');
  var result = mask
      .replaceAll('[N]', name)
      .replaceAll('[E]', ext)
      .replaceAll('[C]', counter)
      .replaceAll('[Y]', stamp.year.toString().padLeft(4, '0'))
      .replaceAll('[M]', stamp.month.toString().padLeft(2, '0'))
      .replaceAll('[D]', stamp.day.toString().padLeft(2, '0'))
      .replaceAll('[h]', stamp.hour.toString().padLeft(2, '0'))
      .replaceAll('[m]', stamp.minute.toString().padLeft(2, '0'))
      .replaceAll('[s]', stamp.second.toString().padLeft(2, '0'));
  if (!mask.contains('[E]') && ext.isNotEmpty) {
    result = '$result.$ext';
  }
  return result;
}

/// Splits `file.tar.gz` into `file.tar` + `gz`, `notes` into `notes` + ''.
(String, String) splitFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0 || dot == fileName.length - 1) return (fileName, '');
  return (fileName.substring(0, dot), fileName.substring(dot + 1));
}

/// Builds the preview: one entry per source name, with collisions flagged.
List<RenameRow> buildRenamePreview({
  required List<String> names,
  required String mask,
  String find = '',
  String replace = '',
  bool useRegExp = false,
  DateTime? now,
}) {
  final result = <RenameRow>[];
  RegExp? pattern;
  if (find.isNotEmpty && useRegExp) {
    try {
      pattern = RegExp(find);
    } on FormatException {
      pattern = null;
    }
  }
  final seen = <String>{};

  for (var i = 0; i < names.length; i++) {
    final (name, ext) = splitFileName(names[i]);
    var next = applyRenameMask(
      mask,
      name: name,
      ext: ext,
      index: i,
      total: names.length,
      now: now,
    );
    if (find.isNotEmpty) {
      next = pattern != null
          ? next.replaceAll(pattern, replace)
          : next.replaceAll(find, replace);
    }

    String? problem;
    final (stem, _) = splitFileName(next);
    if (next.trim().isEmpty || stem.trim().isEmpty) {
      problem = 'пустое имя';
    } else if (next.contains('/') || next.contains(r'\')) {
      problem = 'имя содержит разделитель пути';
    } else if (!seen.add(next.toLowerCase())) {
      problem = 'дубликат имени';
    }
    result.add((from: names[i], to: next, problem: problem));
  }
  return result;
}

/// True when the preview can be applied (no problems, at least one change).
bool canApplyRename(List<RenameRow> preview) {
  if (preview.isEmpty) return false;
  if (preview.any((row) => row.problem != null)) return false;
  return preview.any((row) => row.from != row.to);
}
