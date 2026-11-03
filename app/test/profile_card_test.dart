import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova/features/settings/profile_card.dart';

/// The export flow must not ask for a password any more: one confirmation
/// dialog, then the system file dialog.
void main() {
  testWidgets('export asks for confirmation without a password field', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileCard(
            dataDir: r'C:\temp\profile',
            deviceKeyVault: true,
            onImported: () async {},
          ),
        ),
      ),
    );

    expect(find.text(r'C:\temp\profile'), findsOneWidget);
    expect(find.textContaining('ключом этого компьютера'), findsOneWidget);

    await tester.tap(find.text('Экспортировать профиль…'));
    await tester.pumpAndSettle();

    expect(find.text('Экспортировать профиль?'), findsOneWidget);
    // The warning mentions the plain-text passwords.
    expect(find.textContaining('не шифруется'), findsOneWidget);
    // No password input anywhere in the dialog.
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(EditableText), findsNothing);

    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.text('Экспортировать профиль?'), findsNothing);
  });

  testWidgets('import asks merge or replace, without a password', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileCard(
            dataDir: r'C:\temp\profile',
            onImported: () async {},
          ),
        ),
      ),
    );
    // The merge dialog itself is opened only after the system file picker, so
    // there is nothing to assert here beyond the card being password-free.
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('Импортировать профиль'), findsOneWidget);
  });
}
