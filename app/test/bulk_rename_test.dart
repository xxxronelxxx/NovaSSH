import 'package:flutter_test/flutter_test.dart';
import 'package:nova/features/browser/bulk_rename.dart';

void main() {
  test('counter is padded to the number of files', () {
    expect(
      applyRenameMask('[N]_[C]', name: 'photo', ext: 'jpg', index: 0, total: 9),
      'photo_1.jpg',
    );
    expect(
      applyRenameMask('[N]_[C]', name: 'photo', ext: 'jpg', index: 11, total: 12),
      'photo_12.jpg',
    );
  });

  test('the extension survives a mask without [E]', () {
    expect(
      applyRenameMask('[N]-backup', name: 'site', ext: 'zip', index: 0, total: 2),
      'site-backup.zip',
    );
  });

  test('[E] replaces the extension explicitly', () {
    expect(
      applyRenameMask('[N].[E]', name: 'file.tar', ext: 'gz', index: 0, total: 1),
      'file.tar.gz',
    );
    expect(
      applyRenameMask('[N]', name: 'notes', ext: '', index: 0, total: 1),
      'notes',
    );
  });

  test('date tokens use the given date', () {
    expect(
      applyRenameMask(
        '[Y]-[M]-[D]',
        name: 'a',
        ext: 'txt',
        index: 0,
        total: 1,
        now: DateTime(2026, 3, 7),
      ),
      '2026-03-07.txt',
    );
  });

  test('splitFileName keeps dotfiles and multi-part extensions', () {
    expect(splitFileName('archive.tar.gz'), ('archive.tar', 'gz'));
    expect(splitFileName('.bashrc'), ('.bashrc', ''));
    expect(splitFileName('plain'), ('plain', ''));
  });

  test('preview flags duplicates and empty names', () {
    final dup = buildRenamePreview(names: ['a.txt', 'b.txt'], mask: 'same.[E]');
    expect(dup.map((r) => r.problem).toList(), [null, 'дубликат имени']);

    final empty = buildRenamePreview(names: ['a.txt'], mask: '   ');
    expect(empty.single.problem, 'пустое имя');
  });

  test('find and replace runs over the result', () {
    final preview = buildRenamePreview(
      names: ['IMG_001.JPG', 'IMG_002.JPG'],
      mask: '[N]',
      find: 'IMG',
      replace: 'photo',
    );
    expect(preview[0].to, 'photo_001.JPG');
    expect(preview[1].to, 'photo_002.JPG');
  });

  test('regex replacement is used when enabled', () {
    final preview = buildRenamePreview(
      names: ['a1.txt'],
      mask: '[N]',
      find: r'\d+',
      replace: 'X',
      useRegExp: true,
    );
    expect(preview.single.to, 'aX.txt');
  });

  test('nothing changed means nothing to apply', () {
    final same = buildRenamePreview(names: ['a.txt'], mask: '[N]');
    expect(canApplyRename(same), isFalse);

    final changed = buildRenamePreview(names: ['a.txt'], mask: '[N]_[C]');
    expect(canApplyRename(changed), isTrue);
  });
}
