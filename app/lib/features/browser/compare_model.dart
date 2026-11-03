import '../../bridge/model.dart';

/// A run of consecutive differing rows in the compare list.
class DiffHunk {
  const DiffHunk(this.start, this.end);

  /// First differing row (inclusive).
  final int start;

  /// One past the last differing row.
  final int end;

  bool contains(int row) => row >= start && row < end;
}

/// Groups consecutive non-equal rows into blocks.
List<DiffHunk> buildHunks(List<DiffRow> rows) {
  final hunks = <DiffHunk>[];
  var start = -1;
  for (var i = 0; i < rows.length; i++) {
    final differs = rows[i].kind != 'equal';
    if (differs && start < 0) start = i;
    if (!differs && start >= 0) {
      hunks.add(DiffHunk(start, i));
      start = -1;
    }
  }
  if (start >= 0) hunks.add(DiffHunk(start, rows.length));
  return hunks;
}

/// Copies a whole block of differences into the opposite document.
///
/// `intoLeft` copies the right side of the block over the left document (and
/// the other way round). Pure inserts are placed after the last line that both
/// documents share before the block; pure deletes remove the block from the
/// target. Mutates [left] or [right] in place.
void applyHunkToDocuments(
  List<DiffRow> rows,
  DiffHunk hunk, {
  required bool intoLeft,
  required List<String> left,
  required List<String> right,
}) {
  final block = rows.sublist(hunk.start, hunk.end);
  final source = <String>[
    for (final row in block)
      if ((intoLeft ? row.right : row.left) != null)
        (intoLeft ? row.right! : row.left!).text,
  ];
  final targets = <int>[
    for (final row in block)
      if ((intoLeft ? row.left : row.right) != null)
        (intoLeft ? row.left! : row.right!).number,
  ];

  final doc = intoLeft ? left : right;
  if (targets.isEmpty) {
    // The target has no lines in this block, so it is a pure insertion.
    var before = 0;
    for (var i = 0; i < hunk.start; i++) {
      final number = intoLeft ? rows[i].left?.number : rows[i].right?.number;
      if (number != null) before = number;
    }
    doc.insertAll(before.clamp(0, doc.length), source);
    return;
  }

  final start = targets.first - 1;
  final count = targets.last - targets.first + 1;
  doc.replaceRange(start, (start + count).clamp(start, doc.length), source);
}
