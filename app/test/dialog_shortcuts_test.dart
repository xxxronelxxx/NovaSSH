import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova/design/ui.dart';

void main() {
  testWidgets('Enter confirms a dialog, Esc cancels it', (tester) async {
    String? result;
    final context = GlobalKey<NavigatorState>();

    Future<void> open() async {
      unawaited(
        showDialog<String>(
          context: context.currentContext!,
          builder: (ctx) => DialogShortcuts(
            onConfirm: () => Navigator.pop(ctx, 'confirm'),
            onCancel: () => Navigator.pop(ctx, 'cancel'),
            child: const AlertDialog(
              title: Text('Удалить?'),
            ),
          ),
        ).then((value) => result = value),
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: context,
        home: const Scaffold(body: SizedBox()),
      ),
    );

    await open();
    expect(find.text('Удалить?'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result, 'confirm');

    result = null;
    await open();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(result, 'cancel');
  });
}
