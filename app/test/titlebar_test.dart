import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova/app/nova.dart';
import 'package:nova/bridge/api.dart';
import 'package:nova/design/theme.dart';
import 'package:nova/design/tokens.dart';
import 'package:nova/features/settings/settings_page.dart';
import 'package:nova/main.dart';

/// The caption lives above the Navigator, so it must push through the root key.
/// Settings used to be opened from here; since `cdb2779` there is exactly one
/// settings button, in the page toolbar, and this test keeps the caption from
/// growing a duplicate.
void main() {
  testWidgets('the caption has no second settings button', (tester) async {
    final nova = NovaController();
    nova.info = const AppInfo(
      dataDir: r'C:\temp\nova',
      keyWrap: 'Available',
      vault: 'unlocked',
      hasDeviceKey: true,
      version: '0.1.0',
      platform: 'windows',
    );

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        theme: buildNovaTheme(),
        builder: (context, child) => Column(
          children: [
            NovaTitleBar(nova: nova),
            Expanded(child: child ?? const SizedBox.shrink()),
          ],
        ),
        home: const Scaffold(body: Text('home')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
    // The single settings button lives in the page toolbar, not in the caption.
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    expect(find.byType(SettingsPage), findsNothing);
  });

  testWidgets('titlebar theme toggle flips the palette', (tester) async {
    final nova = NovaController();
    nova.info = const AppInfo(
      dataDir: '',
      keyWrap: 'Available',
      vault: 'unlocked',
      hasDeviceKey: true,
      version: '0.1.0',
      platform: 'windows',
    );

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        theme: buildNovaTheme(),
        builder: (context, child) => Column(
          children: [
            NovaTitleBar(nova: nova),
            Expanded(child: child ?? const SizedBox.shrink()),
          ],
        ),
        home: const Scaffold(body: Text('home')),
      ),
    );

    final wasDark = T.brightness == Brightness.dark;
    await tester.tap(
      find.byIcon(
        wasDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
      ),
    );
    await tester.pumpAndSettle();
    expect(T.brightness == Brightness.dark, isNot(wasDark));
  });
}
