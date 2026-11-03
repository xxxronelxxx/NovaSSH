import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova/design/ui.dart';

void main() {
  test('byte formatting uses binary units', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1024), '1.00 КБ');
    expect(formatBytes(1536), '1.50 КБ');
    expect(formatBytes(1024 * 1024 * 5), '5.00 МБ');
  });

  test('path helpers behave like the Rust core', () {
    expect(joinPath('/var/www', 'site'), '/var/www/site');
    expect(joinPath('/', 'etc'), '/etc');
    expect(parentPath('/root/wb2'), '/root');
    expect(parentPath('/root'), '/');
    expect(fileName('/root/wb2/readme.txt'), 'readme.txt');
  });

  test('glob matching supports braces', () {
    expect(globToRegExp('*.php')!.hasMatch('Index.PHP'), isTrue);
    expect(globToRegExp('*.{zip,tar,gz}')!.hasMatch('backup.tar'), isTrue);
    expect(globToRegExp('*.php')!.hasMatch('index.php.bak'), isFalse);
  });

  testWidgets('primary button renders label', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PrimaryButton(label: 'Подключиться', onPressed: () {}),
        ),
      ),
    );
    expect(find.text('Подключиться'), findsOneWidget);
  });
}
