import 'dart:io';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:quick_actions/quick_actions.dart';

import '../bridge/api.dart';
import '../bridge/model.dart';
import '../design/ui.dart';

/// Application state holder. Kept deliberately plain (`ChangeNotifier`) so the
/// UI has no dependency on a state-management package.
class NovaController extends ChangeNotifier {
  AppInfo? info;
  ServerBook book = ServerBook(version: 1, groups: [], servers: []);
  Settings? settings;
  ColorRules rules = ColorRules(version: 1, rules: []);
  SessionState? state;

  String? lastError;

  /// Set by an Android launcher shortcut; the server list opens it once.
  String? pendingServerId;

  void openServerFromShortcut(String id) {
    pendingServerId = id;
    notifyListeners();
  }

  /// Set when a server must be added as a tab of the already open browser.
  String? pendingTabServerId;

  void queueTabFromShortcut(String id) {
    pendingTabServerId = id;
    notifyListeners();
  }

  /// Live theme preview from the settings screen, before "Сохранить".
  String? _themeOverride;
  String get themeMode => _themeOverride ?? settings?.window.theme ?? 'dark';

  bool get ready => info != null;
  bool get unlocked => info?.vault == 'unlocked';
  bool get hasVault => (info?.vault ?? 'missing') != 'missing';

  Future<void> boot(String? dataDir) async {
    info = await initDataDir(dataDir: dataDir);
    await reload();
  }

  void previewTheme(String theme) {
    _themeOverride = theme;
    notifyListeners();
  }

  /// Live preview of the appearance tab: applied to `T` without touching disk.
  /// Cleared by [applySettings] or [clearAppearancePreview].
  AppearanceSettings? _appearancePreview;

  AppearanceSettings? get appearancePreview => _appearancePreview;

  void previewAppearance(AppearanceSettings appearance) {
    _appearancePreview = appearance;
    notifyListeners();
  }

  void clearAppearancePreview() {
    if (_appearancePreview == null) return;
    _appearancePreview = null;
    notifyListeners();
  }

  Future<void> applySettings(Settings updated) async {
    await saveSettings(settings: updated);
    _themeOverride = null;
    _appearancePreview = null;
    await reload();
  }

  /// Stores the Ctrl+D bookmarks of one panel without touching other settings.
  Future<void> saveBookmarks({
    required bool remote,
    required List<String> paths,
  }) async {
    final s = settings;
    if (s == null) return;
    final panels = PanelSettings(
      layout: s.panels.layout,
      showHidden: s.panels.showHidden,
      rowDensity: s.panels.rowDensity,
      syncNavigation: s.panels.syncNavigation,
      comparePanels: s.panels.comparePanels,
      tabsEnabled: s.panels.tabsEnabled,
      quickFilter: s.panels.quickFilter,
      localBookmarks: remote ? s.panels.localBookmarks : List.of(paths),
      remoteBookmarks: remote ? List.of(paths) : s.panels.remoteBookmarks,
    );
    await applySettings(
      Settings(
        version: s.version,
        locale: s.locale,
        keymapPreset: s.keymapPreset,
        appearance: s.appearance,
        panels: panels,
        transfer: s.transfer,
        editor: s.editor,
        terminal: s.terminal,
        security: s.security,
        window: s.window,
      ),
    );
  }

  Future<void> applyColorRules(List<ColorRule> rules) async {
    await saveColorRules(rules: ColorRules(version: 1, rules: rules));
    await reload();
  }

  Future<void> forgetDevice() async {
    await forgetMasterKey();
  }

  Future<void> reload() async {
    book = await loadBook();
    settings = await loadSettings();
    rules = await loadColorRules();
    state = await loadSessionState();
    info = await info_();
    notifyListeners();
    _refreshShortcuts();
  }

  /// Launcher shortcuts: the three most recently used servers.
  void _refreshShortcuts() {
    if (kIsWeb) return;
    final recent = [...book.servers]
      ..sort((a, b) => (b.lastConnected ?? 0).compareTo(a.lastConnected ?? 0));
    final items = [
      for (final server in recent.take(3))
        ShortcutItem(
          type: 'server:${server.id}',
          localizedTitle: server.name.trim().isEmpty
              ? '${server.user}@${server.host}'
              : server.name,
        ),
    ];
    unawaited(const QuickActions().setShortcutItems(items).catchError((_) {}));
  }

  Future<AppInfo> info_() => infoUpdate();

  /// Windows keeps no master password: a random key is wrapped by DPAPI and
  /// the vault opens by itself.
  bool get deviceKeyPlatform => !kIsWeb && Platform.isWindows;

  /// True when the silent device-key open failed, so the password screen is
  /// needed: either an old profile without a wrapped key, or a profile whose
  /// wrapped key does not match the vault file.
  bool get needsPasswordMigration => deviceKeyPlatform && hasVault && !unlocked;

  /// Opens (or creates) the vault without asking for anything on Windows.
  ///
  /// Returns true when the vault ended up unlocked. False means the profile is
  /// still password-protected and [migrateToDeviceKey] must be used.
  Future<bool> ensureDeviceVault() async {
    if (!deviceKeyPlatform) return unlocked;
    try {
      if (!hasVault) {
        await createVaultWithDeviceKey();
        await _refreshVaultState();
        return true;
      }
      if (unlocked) {
        // Upgrade a password vault transparently: the key is already wrapped.
        if (await upgradeVaultToDeviceKey()) await _refreshVaultState();
        return true;
      }
      if (info?.hasDeviceKey ?? false) {
        final ok = await unlockWithDevice();
        if (!ok) return false;
        await reload();
        if (await upgradeVaultToDeviceKey()) await _refreshVaultState();
        return unlocked;
      }
    } catch (_) {
      // Fall through to the password screen.
    }
    return false;
  }

  /// One-time migration: decrypt with the old password, re-encrypt with a
  /// random key and forget the password for good.
  Future<void> migrateToDeviceKey(String password) async {
    await rekeyVaultToDeviceKey(password: password);
    await reload();
  }

  Future<void> createVault(String password) async {
    await createVault_(password: password);
    await _refreshVaultState();
  }

  Future<void> unlock(String password) async {
    await unlockVault(password: password);
    await _refreshVaultState();
  }

  Future<bool> unlockWithDevice() async {
    final ok = await unlockVaultWithDevice();
    if (ok) await _refreshVaultState();
    return ok;
  }

  Future<void> lock() async {
    await lockVault();
    await _refreshVaultState();
  }

  Future<void> _refreshVaultState() async {
    info = await infoUpdate();
    notifyListeners();
  }

  Future<void> rememberDevice() async {
    try {
      await rememberMasterKey();
    } catch (_) {
      // Keystore wrapping is optional; ignoring keeps the flow alive.
    }
  }

  Future<Server> saveServer(
    Server server, {
    String? password,
    String? passphrase,
  }) async {
    final saved = await saveServer_(server: server);
    if (password != null && password.isNotEmpty && unlocked) {
      final ref = saved.passwordRef ?? 'pwd_${saved.id}';
      await setSecret(id: ref, value: password);
    }
    if (passphrase != null &&
        passphrase.isNotEmpty &&
        saved.auth.passphraseRef != null &&
        unlocked) {
      await setSecret(id: saved.auth.passphraseRef!, value: passphrase);
    }
    await reload();
    return saved;
  }

  Future<void> deleteServer(String id) async {
    await deleteServer_(id: id);
    await reload();
  }

  Future<Group> saveGroup(Group group) async {
    final saved = await saveGroup_(group: group);
    await reload();
    return saved;
  }

  Future<void> deleteGroup(String id) async {
    await deleteGroup_(id: id);
    await reload();
  }

  Future<ConnectResult> connect(Server server, {String? password}) async {
    final result = await connect_(serverId: server.id, password: password);
    await rememberSession(
      serverId: server.id,
      remotePath: result.startPath,
      localPath: (state?.recentLocal.isNotEmpty ?? false)
          ? state!.recentLocal.first
          : '',
    );
    await reload();
    return result;
  }

  Future<void> remember(String serverId, String remote, String local) async {
    try {
      await rememberSession(
        serverId: serverId,
        remotePath: remote,
        localPath: local,
      );
    } catch (_) {
      // Session memory is best-effort.
    }
  }

  /// Session memory for a server, if any.
  ServerSession? sessionFor(String serverId) {
    for (final record in state?.servers ?? const <ServerSessionRecord>[]) {
      if (record.serverId == serverId) return record.session;
    }
    return null;
  }

  /// Colour rule for a file name; `scope` is `local` or `remote`.
  ColorRule? ruleFor(String name, String scope) {
    final candidates =
        rules.rules
            .where((r) => r.enabled && (r.scope == 'both' || r.scope == scope))
            .toList()
          ..sort((a, b) => a.priority.compareTo(b.priority));
    for (final rule in candidates.reversed) {
      if (rule.isRegex) {
        try {
          if (RegExp(rule.pattern, caseSensitive: false).hasMatch(name)) {
            return rule;
          }
        } catch (_) {
          continue;
        }
      } else {
        final pattern = globToRegExp(rule.pattern);
        if (pattern != null && pattern.hasMatch(name)) return rule;
      }
    }
    return null;
  }
}

/// Thin aliases: the generated bridge uses the same names as the Rust
/// functions, which collide with controller methods.
Future<AppInfo> infoUpdate() => info();
Future<void> createVault_({required String password}) =>
    createVault(password: password);
Future<Server> saveServer_({required Server server}) =>
    saveServer(server: server);
Future<void> deleteServer_({required String id}) => deleteServer(id: id);
Future<Group> saveGroup_({required Group group}) => saveGroup(group: group);
Future<void> deleteGroup_({required String id}) => deleteGroup(id: id);
Future<ConnectResult> connect_({required String serverId, String? password}) =>
    connect(serverId: serverId, password: password);
