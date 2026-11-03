/// Range helper for shift-click selection in the file panels.
///
/// Returns the paths from `from` to `to` inclusive, in either direction.
/// Indices are clamped to the list, so a stale cursor or anchor cannot crash.
List<String> rangeSelection(List<String> paths, int from, int to) {
  if (paths.isEmpty) return const [];
  final a = from.clamp(0, paths.length - 1);
  final b = to.clamp(0, paths.length - 1);
  final start = a < b ? a : b;
  final end = a < b ? b : a;
  return paths.sublist(start, end + 1);
}
