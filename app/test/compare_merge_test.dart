import 'package:flutter_test/flutter_test.dart';
import 'package:nova/bridge/model.dart';
import 'package:nova/features/browser/compare_model.dart';

DiffLine ln(int number, String text) =>
    DiffLine(number: number, text: text, words: const []);

DiffRow row(String kind, {DiffLine? left, DiffLine? right}) =>
    DiffRow(kind: kind, left: left, right: right);

void main() {
  test('hunks group consecutive differing rows', () {
    final rows = [
      row('equal', left: ln(1, 'a'), right: ln(1, 'a')),
      row('mod', left: ln(2, 'b'), right: ln(2, 'B')),
      row('del', left: ln(3, 'c')),
      row('equal', left: ln(4, 'd'), right: ln(3, 'd')),
      row('add', right: ln(4, 'e')),
    ];
    final hunks = buildHunks(rows);
    expect(hunks.length, 2);
    expect(hunks[0].start, 1);
    expect(hunks[0].end, 3);
    expect(hunks[1].start, 4);
    expect(hunks[1].end, 5);
    expect(hunks[0].contains(2), isTrue);
    expect(hunks[0].contains(3), isFalse);
  });

  test('a changed block replaces the left line', () {
    final rows = [
      row('equal', left: ln(1, 'a'), right: ln(1, 'a')),
      row('mod', left: ln(2, 'old'), right: ln(2, 'new')),
    ];
    final left = ['a', 'old'];
    final right = ['a', 'new'];
    applyHunkToDocuments(
      rows,
      buildHunks(rows).first,
      intoLeft: true,
      left: left,
      right: right,
    );
    expect(left, ['a', 'new']);
    expect(right, ['a', 'new']);
  });

  test('an added block is inserted into the left document', () {
    final rows = [
      row('equal', left: ln(1, 'a'), right: ln(1, 'a')),
      row('add', right: ln(2, 'b')),
      row('add', right: ln(3, 'c')),
      row('equal', left: ln(2, 'd'), right: ln(4, 'd')),
    ];
    final left = ['a', 'd'];
    final right = ['a', 'b', 'c', 'd'];
    applyHunkToDocuments(
      rows,
      buildHunks(rows).first,
      intoLeft: true,
      left: left,
      right: right,
    );
    expect(left, ['a', 'b', 'c', 'd']);
  });

  test('a deleted block is removed from the left document', () {
    final rows = [
      row('equal', left: ln(1, 'a'), right: ln(1, 'a')),
      row('del', left: ln(2, 'b')),
      row('equal', left: ln(3, 'c'), right: ln(2, 'c')),
    ];
    final left = ['a', 'b', 'c'];
    final right = ['a', 'c'];
    applyHunkToDocuments(
      rows,
      buildHunks(rows).first,
      intoLeft: true,
      left: left,
      right: right,
    );
    expect(left, ['a', 'c']);
  });

  test('a mixed block is copied into the right document', () {
    // left: a, X, Y   right: a, Z
    final rows = [
      row('equal', left: ln(1, 'a'), right: ln(1, 'a')),
      row('mod', left: ln(2, 'X'), right: ln(2, 'Z')),
      row('del', left: ln(3, 'Y')),
    ];
    final left = ['a', 'X', 'Y'];
    final right = ['a', 'Z'];
    applyHunkToDocuments(
      rows,
      buildHunks(rows).first,
      intoLeft: false,
      left: left,
      right: right,
    );
    expect(right, ['a', 'X', 'Y']);
    expect(left, ['a', 'X', 'Y']);
  });

  test('applying a block twice is stable', () {
    final rows = [
      row('mod', left: ln(1, 'x'), right: ln(1, 'y')),
    ];
    final left = ['x'];
    final right = ['y'];
    final hunk = buildHunks(rows).first;
    applyHunkToDocuments(rows, hunk, intoLeft: true, left: left, right: right);
    applyHunkToDocuments(rows, hunk, intoLeft: true, left: left, right: right);
    expect(left, ['y']);
    expect(left.length, 1);
  });
}
