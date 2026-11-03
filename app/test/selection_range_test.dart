import 'package:flutter_test/flutter_test.dart';
import 'package:nova/features/browser/selection_range.dart';

void main() {
  test('range forwards and backwards is inclusive', () {
    final paths = ['a', 'b', 'c', 'd', 'e'];
    expect(rangeSelection(paths, 1, 3), ['b', 'c', 'd']);
    expect(rangeSelection(paths, 3, 1), ['b', 'c', 'd']);
    expect(rangeSelection(paths, 2, 2), ['c']);
  });

  test('indices are clamped to the list', () {
    final paths = ['a', 'b'];
    expect(rangeSelection(paths, -5, 10), ['a', 'b']);
    expect(rangeSelection(paths, 99, 99), ['b']);
  });

  test('an empty list yields nothing', () {
    expect(rangeSelection(const [], 0, 3), isEmpty);
  });
}
