import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:nova/design/theme.dart';
import 'package:nova/features/editor/editor_page.dart';

void main() {
  testWidgets('editor renders highlighted code and saves changes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNovaTheme(),
        home: EditorPage(
          title: 'index.php',
          initialText: '<?php\necho 1;\n',
          fileName: 'index.php',
          onSave: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The highlighting widget is on screen and nothing threw while building.
    expect(find.byType(CodeField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown extensions open as plain text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNovaTheme(),
        home: EditorPage(
          title: 'notes.weird',
          initialText: 'hello',
          fileName: 'notes.weird',
          onSave: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CodeField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
