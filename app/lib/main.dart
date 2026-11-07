import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:path_provider/path_provider.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:window_manager/window_manager.dart';

import 'app/nova.dart';
import 'bridge/frb_generated.dart';
import 'bridge/model.dart';
import 'design/palette.dart';
import 'design/theme.dart';
import 'design/tokens.dart';
import 'bridge/api.dart' as bridge;
import 'design/ui.dart';
import 'features/connections/connections_page.dart';
import 'features/transfer_service.dart';
import 'features/vault/vault_gate.dart';

bool get isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Writes a startup failure next to the profile.
///
/// A crash before `runApp` leaves the window blank, and the usual logger needs
/// the Rust bridge, which may be exactly what failed.
void _logStartup(Object error, StackTrace stack) {
  try {
    final exe = File(Platform.resolvedExecutable).parent.path;
    final dir = Directory('$exe${Platform.pathSeparator}profile');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}startup-error.txt')
        .writeAsStringSync(
          '${DateTime.now()} :: $error\n$stack\n',
          mode: FileMode.append,
        );
  } catch (_) {
    // Nothing else to do: the app is already broken.
  }
}

/// The caption is built above the Navigator (so it survives route pushes),
/// therefore it must push routes through this key instead of a local context.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Last brightness the window backdrop was configured for.
Brightness? _backdropBrightness;
Future<void> main() async {
  // Everything (bindings, engine, UI) lives in one guarded zone, otherwise
  // Flutter reports a zone mismatch and the error hook is not reliable.
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      ErrorWidget.builder = (details) => _FatalPanel(details: details);
      // A failed core init used to leave the system splash forever: the zone
      // handler below needs the bridge itself, so the real error was lost.
      try {
        await NovaCore.init();
      } catch (e, stack) {
        debugPrint('nova: core init failed: $e $stack');
        runApp(_StartupErrorApp(message: e.toString()));
        return;
      }
      String? dataDir;
      if (Platform.isAndroid || Platform.isIOS) {
        final dir = await getApplicationSupportDirectory();
        dataDir = dir.path;
      }
      final nova = NovaController();
      String? bootError;
      try {
        await nova.boot(dataDir);
        if (nova.deviceKeyPlatform) {
          // Windows has no master password: the vault opens with the DPAPI key.
          await nova.ensureDeviceVault();
        } else if (nova.hasVault && !nova.unlocked) {
          final remember = nova.settings?.security.rememberMasterKey ?? true;
          if (remember) {
            final ok = await nova.unlockWithDevice().catchError((_) => false);
            if (ok) await nova.reload();
          }
        }
      } catch (e, stack) {
        bootError = e.toString();
        _logStartup(e, stack);
      }
      FlutterError.onError = (details) {
        bridge.appendLog(
          line:
              'FLUTTER: ${details.exceptionAsString()} @ ${details.library} :: ${details.stack}',
        );
        FlutterError.presentError(details);
      };
      // The backdrop is created before the first Flutter frame, so the palette
      // must already match the saved theme.
      T.use(
        (nova.settings?.window.theme ?? 'dark') == 'light'
            ? lightPalette
            : darkPalette,
      );
      TransferService.init();
      // Launcher shortcuts (long press on the icon) open a server directly.
      // Launcher shortcuts exist on Android only; on desktop the plugin has no
      // implementation and would throw before the first frame.
      if (!kIsWeb && Platform.isAndroid) {
        try {
          const quickActions = QuickActions();
          await quickActions.initialize((type) {
            if (type.startsWith('server:')) {
              nova.openServerFromShortcut(type.substring('server:'.length));
            }
          });
        } catch (e) {
          debugPrint('nova: quick actions unavailable: $e');
        }
      }
      // Window chrome first, but never let the plugin hold the first frame:
      // a stuck method channel used to leave a blank window with no way in.
      try {
        await _configureWindow(nova.settings?.window.solidMode ?? false)
            .timeout(const Duration(seconds: 5));
      } catch (e, stack) {
        _logStartup(e, stack);
      }
      _installFrameTelemetry();
      runApp(NovaApp(nova: nova, bootError: bootError));
    },
    (error, stack) {
      debugPrint('nova: zone error: $error :: $stack');
      _logStartup(error, stack);
      try {
        bridge.appendLog(line: 'ZONE: $error :: $stack');
      } catch (_) {
        // The bridge itself may be what failed; nothing else to report to.
      }
    },
  );
}

/// Applies (or removes) the Mica backdrop. Also used by the settings toggle.
bool _acrylicReady = false;
Future<void> applyWindowEffect(bool solid) async {
  if (!Platform.isWindows) return;
  try {
    if (!_acrylicReady) {
      await acrylic.Window.initialize();
      _acrylicReady = true;
    }
    await acrylic.Window.setEffect(
      effect: solid ? acrylic.WindowEffect.disabled : acrylic.WindowEffect.mica,
      dark: T.brightness == Brightness.dark,
    );
  } catch (e) {
    // Unsupported build/GPU: the solid theme still works.
    debugPrint('nova: acrylic effect failed: $e');
  }
}

Future<void> _configureWindow(bool solid) async {
  if (!Platform.isWindows) return;
  await windowManager.ensureInitialized();
  // Set the window up explicitly instead of `waitUntilReadyToShow`: that helper
  // hides the window and shows it again from a callback, and a callback that
  // never fires leaves nothing but a blank frame.
  await windowManager.setTitle('Nova SSH');
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: true,
  );
  await windowManager.setBackgroundColor(Colors.transparent);
  await windowManager.setSize(const Size(1180, 760));
  await windowManager.setMinimumSize(const Size(980, 600));
  await windowManager.center();
  await windowManager.show();
  await windowManager.focus();
  // The DWM backdrop is only honoured once the window is visible.
  await applyWindowEffect(solid);
}

/// Writes slow-frame statistics to `logs/nova.log` (throttled), so a jank
/// report can be answered with numbers instead of guesses.
void _installFrameTelemetry() {
  final samples = <double>[];
  var lastReport = DateTime.now();
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds / 1000.0;
      final raster = t.rasterDuration.inMicroseconds / 1000.0;
      final ms = math.max(build, raster).toDouble();
      samples.add(ms);
    }
    if (samples.length < 120) return;
    final now = DateTime.now();
    if (now.difference(lastReport).inSeconds < 10) {
      if (samples.length > 600) samples.clear();
      return;
    }
    final sorted = [...samples]..sort();
    final avg = samples.reduce((a, b) => a + b) / samples.length;
    final p95 =
        sorted[(sorted.length * 0.95).clamp(0, sorted.length - 1).toInt()];
    if (p95 > 20) {
      bridge.appendLog(
        line:
            'PERF frames=${samples.length} avg=${avg.toStringAsFixed(1)}ms '
            'p95=${p95.toStringAsFixed(1)}ms window=${now.difference(lastReport).inSeconds}s',
      );
    }
    samples.clear();
    lastReport = now;
  });
}

class _FatalPanel extends StatelessWidget {
  const _FatalPanel({required this.details});
  final FlutterErrorDetails details;
  @override
  Widget build(BuildContext context) {
    return Container(
      color: T.panel,
      padding: EdgeInsets.all(16),
      child: DefaultTextStyle(
        style: TextStyle(color: T.error, fontSize: 12, fontFamily: T.monoFont),
        child: SingleChildScrollView(
          child: Text('Ошибка интерфейса: ${details.exceptionAsString()}'),
        ),
      ),
    );
  }
}

/// Shown when the Rust core cannot be loaded at all (wrong .so, bridge
/// mismatch). Without it the app just sits on the system splash screen.
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF16161A),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Color(0xFFE6E6E6),
              fontSize: 13,
              fontFamily: 'monospace',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'NovaSSH не смогла загрузить ядро',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFF6B6B),
                  ),
                ),
                const SizedBox(height: 12),
                Text(message),
                const SizedBox(height: 16),
                const Text(
                  'Обычно это означает, что установлен APK со старой '
                  'libnova_core.so. Переустановите свежую сборку.',
                  style: TextStyle(color: Color(0xFF9BA1A6)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class NovaApp extends StatelessWidget {
  const NovaApp({super.key, required this.nova, this.bootError});
  final NovaController nova;
  final String? bootError;
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: nova,
      builder: (context, _) {
        final mode = nova.themeMode;
        final brightness = switch (mode) {
          'light' => Brightness.light,
          'system' => PlatformDispatcher.instance.platformBrightness,
          _ => Brightness.dark,
        };
        final appearance = nova.appearancePreview ?? nova.settings?.appearance;
        if (appearance != null) {
          T.useAppearance(
            fileIcons: appearance.fileIcons,
            folderIcons: appearance.folderIcons,
            uiFont: appearance.uiFont,
            monoFont: appearance.monoFont,
            panelFontSize: appearance.panelFontSize,
            panelText: appearance.panelText,
            panelBackground: appearance.panelBackground,
          );
        }
        T.use(brightness == Brightness.light ? lightPalette : darkPalette);
        return MaterialApp(
          navigatorKey: rootNavigatorKey,
          title: 'NovaSSH',
          debugShowCheckedModeBanner: false,
          theme: buildNovaTheme(),
          // The custom caption and the themed backdrop must wrap *every* route,
          // otherwise pushed screens render on the raw (dark Mica) surface.
          builder: (context, child) {
            if (_backdropBrightness != brightness) {
              _backdropBrightness = brightness;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                applyWindowEffect(nova.settings?.window.solidMode ?? false);
              });
            }
            final content = Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [T.shellTop, T.shellBottom],
                ),
              ),
              child: isDesktop
                  ? Column(
                      children: [
                        NovaTitleBar(nova: nova),
                        Expanded(child: child ?? const SizedBox.shrink()),
                      ],
                    )
                  : (child ?? const SizedBox.shrink()),
            );
            return content;
          },
          home: AppShell(nova: nova, bootError: bootError),
        );
      },
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.nova, this.bootError});
  final NovaController nova;
  final String? bootError;
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: nova,
      builder: (context, _) {
        final body = _body();
        return isDesktop ? body : SafeArea(child: body);
      },
    );
  }

  Widget _body() {
    if (bootError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Не удалось инициализировать ядро:\n$bootError',
            textAlign: TextAlign.center,
            style: TextStyle(color: T.error, fontSize: 13),
          ),
        ),
      );
    }
    if (!nova.ready) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (!nova.unlocked) {
      return VaultGate(nova: nova);
    }
    return ConnectionsPage(nova: nova);
  }
}

/// Custom caption: drag region, quick actions and window buttons.
class NovaTitleBar extends StatelessWidget {
  const NovaTitleBar({super.key, required this.nova});
  final NovaController nova;
  void _toggleTheme(BuildContext context) {
    final next = T.brightness == Brightness.light ? 'dark' : 'light';
    nova.previewTheme(next);
    T.use(next == 'light' ? lightPalette : darkPalette);
    applyWindowEffect(nova.settings?.window.solidMode ?? false);
    if (nova.settings != null) {
      final s = nova.settings!;
      nova.applySettings(
        Settings(
          version: 1,
          locale: s.locale,
          keymapPreset: s.keymapPreset,
          appearance: s.appearance,
          panels: s.panels,
          transfer: s.transfer,
          editor: s.editor,
          terminal: s.terminal,
          security: s.security,
          window: WindowSettings(
            backdrop: s.window.backdrop,
            solidMode: s.window.solidMode,
            restoreBounds: s.window.restoreBounds,
            theme: next,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final light = T.brightness == Brightness.light;
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Image.asset('assets/icon.png', width: 16, height: 16),
                    SizedBox(width: 8),
                    Text(
                      'Nova SSH',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        color: T.dim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ToolButton(
            icon: light ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
            onPressed: () => _toggleTheme(context),
          ),
          SizedBox(width: 4),
          _CaptionButton(
            icon: Icons.remove,
            onTap: () => windowManager.minimize(),
          ),
          _CaptionButton(
            icon: Icons.crop_square,
            onTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _CaptionButton(
            icon: Icons.close,
            danger: true,
            onTap: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 46,
          height: 36,
          color: _hover
              ? (widget.danger ? const Color(0xFFC42B1C) : T.hover)
              : Colors.transparent,
          child: Icon(
            widget.icon,
            size: 14,
            color: _hover && widget.danger ? Colors.white : T.dim,
          ),
        ),
      ),
    );
  }
}
