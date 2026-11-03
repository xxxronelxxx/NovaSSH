import 'package:flutter_test/flutter_test.dart';
import 'package:nova/features/browser/transfer_ui.dart';

void main() {
  test('a batch aggregates bytes of every file', () {
    final batch = TransferBatch(
      operation: 'Скачивание',
      destination: 'D:/tmp',
      files: ['a.bin', 'b.bin'],
    );

    batch.update('1', 'a.bin', 1000, 400);
    batch.update('2', 'b.bin', 1000, 0);

    expect(batch.totalBytes, 2000);
    expect(batch.doneBytes, 400);
    expect(batch.progress, closeTo(0.2, 1e-9));
    expect(batch.currentFile, 'b.bin');
    expect(batch.currentItem.done, 0);
    expect(batch.running, isTrue);

    batch.finish('1');
    batch.finish('2');
    expect(batch.doneBytes, 2000);
    expect(batch.progress, 1);
    expect(batch.complete, isTrue);
    expect(batch.running, isFalse);
  });

  test('a failed file is counted, not hidden as success', () {
    final batch = TransferBatch(
      operation: 'Отправка',
      destination: '/var/www',
      files: ['a', 'b'],
    );
    batch.update('1', 'a', 10, 10);
    batch.update('2', 'b', 10, 3);
    batch.finish('1');
    batch.finish('2', failed: true);

    expect(batch.failed, 1);
    expect(batch.complete, isTrue);
  });

  test('cancelling the window stops every known transfer', () {
    final cancelled = <String>[];
    final batch = TransferBatch(
      operation: 'Отправка',
      destination: '/var/www',
      files: ['a', 'b', 'c'],
      cancelTransfer: cancelled.add,
    )..update('1', 'a', 10, 5);

    batch.cancelAll();
    expect(cancelled, ['1']);
    expect(batch.running, isFalse);

    // A late event must not resurrect the window.
    batch.update('2', 'b', 10, 1);
    expect(batch.running, isFalse);
  });

  test('durations print as m:ss and h:mm:ss', () {
    expect(formatDuration(const Duration(seconds: 9)), '00:09');
    expect(formatDuration(const Duration(minutes: 2, seconds: 5)), '02:05');
    expect(formatDuration(const Duration(hours: 1, minutes: 3)), '1:03:00');
  });
}
