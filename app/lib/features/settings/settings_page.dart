import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/nova.dart';
import '../../bridge/api.dart';
import '../../bridge/model.dart';
import '../../design/tokens.dart';
import '../../design/ui.dart';
import '../ai/ai_client.dart';
import '../snippets/snippet_editor.dart';
import 'profile_card.dart';
import '../logs/logs_page.dart';
import 'qr_scan_page.dart';

/// Asks for a new 4-digit PIN twice.
class _NewPinDialog extends StatefulWidget {
  @override
  State<_NewPinDialog> createState() => _NewPinDialogState();
}

class _NewPinDialogState extends State<_NewPinDialog> {
  final _pin = TextEditingController();
  final _repeat = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _save() {
    final a = _pin.text.trim();
    if (a.length != 4 || int.tryParse(a) == null) {
      setState(() => _error = 'Нужно ровно 4 цифры');
      return;
    }
    if (a != _repeat.text.trim()) {
      setState(() => _error = 'PIN не совпадает');
      return;
    }
    Navigator.pop(context, a);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.menu,
      title: const Text('Новый PIN', style: TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _pin,
              autofocus: true,
              keyboardType: TextInputType.number,
              obscureText: true,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              style: const TextStyle(fontSize: 16, letterSpacing: 6),
              decoration: const InputDecoration(labelText: 'PIN (4 цифры)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _repeat,
              keyboardType: TextInputType.number,
              obscureText: true,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              style: const TextStyle(fontSize: 16, letterSpacing: 6),
              decoration: const InputDecoration(labelText: 'Повторите PIN'),
              onSubmitted: (_) => _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(fontSize: 12, color: T.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(onPressed: _save, child: const Text('Сохранить')),
      ],
    );
  }
}

/// Full settings surface: appearance, panels, editor, terminal, transfers,
/// security, file colours and about/diagnostics.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.nova});

  final NovaController nova;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late Settings _s;
  late List<ColorRule> _rules;
  bool _syncSecrets = false;
  bool _syncBusy = false;
  final TextEditingController _syncUrl = TextEditingController();
  final _editorPath = TextEditingController();
  String? _editorCheck;
  final _winscpIni = TextEditingController(text: 'WinSCP.ini');
  final _terminalCmd = TextEditingController();

  // AI assistant (Настройки → ИИ). The key lives in the vault, not here.
  AiSettings? _ai;
  final _aiKey = TextEditingController();
  final _aiEndpoint = TextEditingController();
  final _aiModel = TextEditingController();
  List<AiModel> _models = const [];
  bool _aiBusy = false;
  String? _aiStatus;
  bool _aiStatusError = false;
  String _aiKeyOriginal = '';
  bool _aiKeyLoaded = false;
  bool _aiKeyVisible = false;

  // Snippets (Настройки → Сниппеты).
  List<Snippet> _snippets = const [];
  bool _snippetsLoading = true;

  // Edit log (Настройки → Редактор и терминал).
  LogSettings _log = const LogSettings(editLog: false);

  @override
  void initState() {
    super.initState();
    _s =
        widget.nova.settings ??
        Settings(
          version: 1,
          locale: 'ru',
          keymapPreset: 'winscp',
          appearance: AppearanceSettings(
            fileIcons: 'colored',
            folderIcons: 'filled',
            uiFont: '',
            monoFont: '',
            panelFontSize: 12,
            panelText: '',
            panelBackground: '',
          ),
          panels: PanelSettings(
            layout: 'dual',
            showHidden: true,
            rowDensity: 'comfortable',
            syncNavigation: true,
            comparePanels: true,
            tabsEnabled: true,
            quickFilter: true,
            localBookmarks: const [],
            remoteBookmarks: const [],
          ),
          transfer: TransferSettings(
            concurrency: 3,
            chunksPerFile: 4,
            chunkKib: 256,
            bandwidthLimitKibps: 0,
            conflictPolicy: 'ask',
            verifyChecksum: 'off',
            preserveTimes: true,
            resume: true,
          ),
          editor: EditorSettings(external_: '', fallbackBuiltin: true),
          terminal: TerminalSettings(
            profiles: [],
            defaultProfile: 'putty',
            androidMode: 'termux',
            builtinXterm: true,
          ),
          security: SecuritySettings(
            lockOnIdleMinutes: 15,
            clipboardClearSeconds: 30,
            rememberMasterKey: true,
            biometricUnlock: true,
          ),
          window: WindowSettings(
            backdrop: 'mica',
            solidMode: false,
            restoreBounds: true,
            theme: 'dark',
          ),
        );
    _rules = [...widget.nova.rules.rules];
    _editorPath.text = _s.editor.external_;
    _terminalCmd.text =
        _s.terminal.profiles
            .where((p) => p.id == (_s.terminal.defaultProfile ?? ''))
            .firstOrNull
            ?.command ??
        '';
    _loadAi();
    _loadSnippets();
    _loadLogSettings();
  }

  Future<void> _loadLogSettings() async {
    try {
      final settings = await loadLogSettings();
      if (!mounted) return;
      setState(() => _log = settings);
    } catch (_) {}
  }

  Future<void> _setEditLog(bool value) async {
    final previous = _log;
    setState(() => _log = LogSettings(editLog: value));
    try {
      await saveLogSettings(settings: _log);
    } catch (e) {
      if (!mounted) return;
      setState(() => _log = previous);
      _syncToast('Журнал: ${friendlyError(e)}', warn: true);
    }
  }

  Future<void> _loadAi() async {
    try {
      final settings = await loadAiSettings();
      final key = await getSecret(id: aiKeyId(settings.provider)) ?? '';
      if (!mounted) return;
      setState(() {
        _ai = settings;
        _aiEndpoint.text = settings.endpoint;
        _aiModel.text = settings.model;
        _aiKey.text = key;
        _aiKeyOriginal = key;
        _aiKeyLoaded = true;
      });
      // Pull the provider's model list on first entry, as agreed: no model is
      // hardcoded, the user picks from what the provider offers.
      if (key.trim().isNotEmpty) {
        await _fetchModels(silent: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiStatus = friendlyError(e);
        _aiStatusError = true;
      });
    }
  }

  Future<void> _loadSnippets() async {
    try {
      final list = await loadSnippets();
      if (!mounted) return;
      setState(() {
        _snippets = list;
        _snippetsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _snippetsLoading = false);
    }
  }

  Future<void> _fetchModels({bool silent = false}) async {
    if (_aiBusy) return;
    final endpoint = _aiEndpoint.text.trim();
    final key = _aiKey.text.trim();
    if (key.isEmpty) {
      setState(() {
        _aiStatus = 'Сначала вставьте API-ключ';
        _aiStatusError = true;
      });
      return;
    }
    setState(() {
      _aiBusy = true;
      _aiStatus = silent ? null : 'Загружаю список моделей…';
      _aiStatusError = false;
    });
    try {
      final client = AiClient(
        endpoint: endpoint,
        apiKey: key,
        model: _aiModel.text.trim(),
      );
      final models = await client.fetchModels();
      if (!mounted) return;
      setState(() {
        _aiBusy = false;
        _models = models;
        if (_aiModel.text.trim().isEmpty && models.isNotEmpty) {
          _aiModel.text = models.first.id;
        }
        _aiStatus =
            'Ключ работает. Моделей: ${models.length}. '
            'Выберите модель в списке.';
        _aiStatusError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiBusy = false;
        _aiStatus = friendlyError(e);
        _aiStatusError = true;
      });
    }
  }

  Future<void> _pickProvider(String provider) async {
    final preset = aiProviders[provider]?.endpoint ?? '';
    setState(() {
      _ai = AiSettings(
        enabled: _ai?.enabled ?? true,
        provider: provider,
        endpoint: preset,
        model: '',
        includeContext: _ai?.includeContext ?? true,
      );
      _aiEndpoint.text = preset;
      _aiModel.text = '';
      _models = const [];
      _aiStatus = null;
      _aiKeyLoaded = false;
      _aiKey.text = '';
      _aiKeyOriginal = '';
    });
    final key = await getSecret(id: aiKeyId(provider)) ?? '';
    if (!mounted || _ai?.provider != provider) return;
    setState(() {
      _aiKey.text = key;
      _aiKeyOriginal = key;
      _aiKeyLoaded = true;
    });
    if (key.trim().isNotEmpty) await _fetchModels(silent: true);
  }

  Future<void> _saveAi() async {
    final ai = _ai;
    if (ai == null) return;
    final updated = AiSettings(
      enabled: ai.enabled,
      provider: ai.provider,
      endpoint: _aiEndpoint.text.trim(),
      model: _aiModel.text.trim(),
      includeContext: ai.includeContext,
    );
    await saveAiSettings(settings: updated);
    if (_aiKeyLoaded && _aiKey.text != _aiKeyOriginal) {
      final trimmed = _aiKey.text.trim();
      if (trimmed.isEmpty) {
        await deleteSecret(id: aiKeyId(updated.provider));
      } else {
        await setSecret(id: aiKeyId(updated.provider), value: trimmed);
      }
      _aiKeyOriginal = _aiKey.text;
    }
    if (mounted) setState(() => _ai = updated);
  }

  bool get _isPhone =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void dispose() {
    widget.nova.clearAppearancePreview();
    _syncUrl.dispose();
    _editorPath.dispose();
    _winscpIni.dispose();
    _terminalCmd.dispose();
    _aiKey.dispose();
    _aiEndpoint.dispose();
    _aiModel.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final updated = Settings(
      version: 1,
      locale: _s.locale,
      keymapPreset: _s.keymapPreset,
      appearance: _s.appearance,
      panels: _s.panels,
      transfer: _s.transfer,
      editor: EditorSettings(
        external_: _editorPath.text.trim(),
        fallbackBuiltin: _s.editor.fallbackBuiltin,
      ),
      terminal: TerminalSettings(
        profiles: [
          for (final p in _s.terminal.profiles)
            TerminalProfile(
              id: p.id,
              name: p.name,
              command: p.id == (_s.terminal.defaultProfile ?? '')
                  ? _terminalCmd.text.trim()
                  : p.command,
              args: p.args,
              allowPasswordArg: p.allowPasswordArg,
            ),
        ],
        defaultProfile: _s.terminal.defaultProfile,
        androidMode: _s.terminal.androidMode,
        builtinXterm: _s.terminal.builtinXterm,
      ),
      security: _s.security,
      window: _s.window,
    );
    await widget.nova.applySettings(updated);
    await widget.nova.applyColorRules(_rules);
    try {
      await _saveAi();
    } catch (e) {
      if (mounted) _syncToast('ИИ: ${friendlyError(e)}', warn: true);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Настройки сохранены',
            style: TextStyle(fontSize: 12.5, color: T.text),
          ),
          backgroundColor: T.panel,
          behavior: SnackBarBehavior.floating,
          width: MediaQuery.sizeOf(context).width - 48 < 360
              ? MediaQuery.sizeOf(context).width - 32
              : 360,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(T.radiusSmall),
            side: BorderSide(color: T.border),
          ),
        ),
      );
    }
  }

  void _setTheme(String theme) {
    setState(() {
      _s = Settings(
        version: 1,
        locale: _s.locale,
        keymapPreset: _s.keymapPreset,
        appearance: _s.appearance,
        panels: _s.panels,
        transfer: _s.transfer,
        editor: _s.editor,
        terminal: _s.terminal,
        security: _s.security,
        window: WindowSettings(
          backdrop: _s.window.backdrop,
          solidMode: _s.window.solidMode,
          restoreBounds: _s.window.restoreBounds,
          theme: theme,
        ),
      );
    });
    // Apply immediately for a live preview.
    widget.nova.previewTheme(theme);
  }

  @override
  Widget build(BuildContext context) {
    // One source of truth for the tab bar and the pages: a mismatch used to
    // break tab switching when a page was added.
    final tabs = <Tab>[
      const Tab(text: 'Внешний вид'),
      const Tab(text: 'Панели'),
      const Tab(text: 'Редактор и терминал'),
      const Tab(text: 'Сниппеты'),
      const Tab(text: 'ИИ'),
      const Tab(text: 'Передачи'),
      // The security page only has controls on Android (the PIN).
      if (_isPhone) const Tab(text: 'Безопасность'),
      const Tab(text: 'Файлы и импорт'),
      const Tab(text: 'Профиль'),
      const Tab(text: 'Синхронизация'),
    ];
    final views = <Widget>[
      _tabView([_appearance()]),
      _tabView([_panels()]),
      _tabView([_editor(), _editLogCard(), _terminal()]),
      _tabView([_snippetsCard()]),
      _tabView([_aiCard()]),
      _tabView([_transfer()]),
      if (_isPhone) _tabView([_security()]),
      _tabView([_colors(), _importCard(), _about()]),
      _tabView([
        ProfileCard(
          dataDir: widget.nova.info?.dataDir ?? '—',
          deviceKeyVault: widget.nova.deviceKeyPlatform,
          onImported: () async {
            await widget.nova.reload();
          },
        ),
      ]),
      _tabView([_sync()]),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        // Opaque enough that the screen underneath cannot show through while the
        // route animates in.
        backgroundColor: T.panel.withValues(alpha: 0.98),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Column(
            children: [
              Row(
                children: [
                  ToolButton(
                    icon: Icons.arrow_back,
                    tooltip: 'Назад',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Настройки',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  PrimaryButton(
                    label: 'Сохранить',
                    icon: Icons.check,
                    onPressed: _save,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Tabs instead of one long scroll: the settings list keeps growing.
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerColor: Colors.transparent,
                indicatorColor: T.accent,
                labelColor: T.text,
                unselectedLabelColor: T.dim,
                labelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelStyle: const TextStyle(fontSize: 12),
                tabs: tabs,
              ),
              const SizedBox(height: 10),
              Expanded(
                // All tabs are built immediately: TabBarView builds lazily and the
                // first build of the heavy cards caused a visible flash.
                child: TabBarView(
                  physics: const NeverScrollableScrollPhysics(),
                  children: views,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabView(List<Widget> children) {
    return ListView(children: children);
  }

  /// Android: re-encrypt the vault with a new 4-digit PIN.
  Future<void> _changePin() async {
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => _NewPinDialog(),
    );
    if (pin == null || !mounted) return;
    try {
      await setVaultPassword(newPassword: pin);
      _syncToast('PIN изменён');
    } catch (e) {
      _syncToast('Не удалось сменить PIN: ${friendlyError(e)}', warn: true);
    }
  }

  // ---------------------------------------------------------------- sync

  Widget _sync() {
    return _card('Синхронизация с телефоном', [
      Text(
        'Без аккаунтов: компьютер показывает QR-код, телефон скачивает профиль '
        'по локальной сети (Wi-Fi). Серверы, группы и настройки переносятся за '
        'один скан. Ссылка одноразовая и живёт 5 минут.',
        style: TextStyle(fontSize: 12, color: T.dim, height: 1.4),
      ),
      const SizedBox(height: 12),
      if (!_isPhone) ...[
        Row(
          children: [
            Checkbox(
              value: _syncSecrets,
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: T.borderStrong),
              onChanged: (v) => setState(() => _syncSecrets = v ?? false),
            ),
            Expanded(
              child: Text(
                'Передавать сохранённые пароли и ключи S3 '
                '(по локальной сети открытым текстом)',
                style: TextStyle(fontSize: 12, color: T.dim),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            PrimaryButton(
              label: 'Показать QR для телефона',
              icon: Icons.qr_code_2,
              onPressed: _showSyncQr,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Телефон должен быть в той же сети, что и компьютер.',
          style: TextStyle(fontSize: 11, color: T.faint),
        ),
      ] else ...[
        Row(
          children: [
            PrimaryButton(
              label: 'Сканировать QR',
              icon: Icons.qr_code_scanner,
              onPressed: _scanSyncQr,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Или вставьте ссылку, которую показывает компьютер:',
          style: TextStyle(fontSize: 11.5, color: T.faint),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _syncUrl,
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(
            hintText: 'http://192.168.0.10:41234/sync?token=…',
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            TextButton(
              onPressed: _syncBusy
                  ? null
                  : () => unawaited(_importSyncUrl(_syncUrl.text.trim())),
              child: const Text('Импортировать по ссылке'),
            ),
            const SizedBox(width: 8),
            if (_syncBusy)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        Text(
          'Пароли придут только если на компьютере включили их передачу и здесь '
          'хранилище разблокировано.',
          style: TextStyle(fontSize: 11, color: T.faint),
        ),
      ],
    ]);
  }

  void _syncToast(String text, {bool warn = false}) {
    if (!mounted) return;
    final screen = MediaQuery.sizeOf(context).width;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // Text on the theme colour, never the default white on a light panel.
        content: Text(text, style: TextStyle(fontSize: 12.5, color: T.text)),
        backgroundColor: warn ? T.warnSurface : T.panel,
        behavior: SnackBarBehavior.floating,
        width: screen - 48 < 520 ? screen - 32 : 520,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.radiusSmall),
          side: BorderSide(color: T.border),
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _showSyncQr() async {
    SyncShare share;
    try {
      share = await startSyncShare(includeSecrets: _syncSecrets);
    } catch (e) {
      _syncToast('Синхронизация: ${friendlyError(e)}', warn: true);
      return;
    }
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.menu,
        title: const Text(
          'Синхронизация с телефоном',
          style: TextStyle(fontSize: 14),
        ),
        content: SizedBox(
          width: MediaQuery.sizeOf(context).width - 64 < 380
              ? MediaQuery.sizeOf(context).width - 64
              : 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: QrImageView(
                  data: share.url,
                  size: 260,
                  backgroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(height: 10),
              SelectableText(
                share.url,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10.5,
                  fontFamily: T.monoFont,
                  color: T.dim,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Откройте на телефоне «Настройки → Синхронизация» и отсканируйте '
                'код. Пароли: ${_syncSecrets ? 'передаются' : 'не передаются'}.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: T.faint),
              ),
              const SizedBox(height: 6),
              Text(
                'Если телефон не подключается — разрешите NovaSSH в брандмауэре '
                'Windows для частных сетей.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10.5, color: T.warn),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: share.url));
              _syncToast('Ссылка скопирована');
            },
            child: const Text('Копировать ссылку'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
    await stopSyncShare();
  }

  Future<void> _scanSyncQr() async {
    final url = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (url == null || url.isEmpty) return;
    await _importSyncUrl(url);
  }

  Future<void> _importSyncUrl(String url) async {
    if (url.isEmpty) return;
    setState(() => _syncBusy = true);
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw 'Сервер ответил ${response.statusCode}. Ссылка уже использована?';
      }
      final body = await response.transform(utf8.decoder).join();
      client.close();

      final report = await importSync(json: body);
      await widget.nova.reload();
      if (!mounted) return;
      setState(() {
        _s = widget.nova.settings ?? _s;
        _rules = widget.nova.rules.rules;
        _syncBusy = false;
        _syncUrl.clear();
      });
      _syncToast(
        'Импортировано: серверов ${report.servers}, групп ${report.groups}, '
        'паролей ${report.secrets}'
        '${report.settings ? ', настройки обновлены' : ''}',
      );
    } catch (e) {
      if (mounted) setState(() => _syncBusy = false);
      _syncToast('Синхронизация: $e', warn: true);
    }
  }

  // ---------------------------------------------------------------- sections

  Widget _card(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: NovaSurface(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                color: T.faint,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String hint, Widget trailing) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 12.5, color: T.text)),
                if (hint.isNotEmpty)
                  Text(hint, style: TextStyle(fontSize: 11, color: T.faint)),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }

  Widget _switch(bool value, ValueChanged<bool> onChange) {
    return Switch(
      value: value,
      onChanged: onChange,
      activeThumbColor: T.accent,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  static const _uiFonts = [
    '',
    'Segoe UI',
    'Tahoma',
    'Verdana',
    'Arial',
    'Inter',
    'Roboto',
  ];
  static const _monoFonts = [
    '',
    'JetBrains Mono',
    'Consolas',
    'Cascadia Mono',
    'Courier New',
    'Roboto Mono',
  ];
  static const _textSwatches = [
    '#E8ECF3',
    '#FFFFFF',
    '#C9D1DB',
    '#F0C04A',
    '#8BE28B',
    '#6CB6FF',
    '#C08CFF',
    '#F07A9B',
  ];
  static const _backgroundSwatches = [
    '#141820',
    '#0B0D12',
    '#1B2029',
    '#0E1622',
    '#151A12',
    '#FFFFFF',
    '#F4F6FA',
    '#FFF8E7',
  ];

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10.5,
        letterSpacing: 0.9,
        fontWeight: FontWeight.w600,
        color: T.faint,
      ),
    ),
  );

  Widget _appearance() {
    final a = _s.appearance;
    return _card('ВНЕШНИЙ ВИД', [
      _row(
        'Тема',
        'Переключается мгновенно',
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'dark',
              label: Text('Тёмная'),
              icon: Icon(Icons.dark_mode, size: 15),
            ),
            ButtonSegment(
              value: 'light',
              label: Text('Светлая'),
              icon: Icon(Icons.light_mode, size: 15),
            ),
            ButtonSegment(value: 'system', label: Text('Системная')),
          ],
          selected: {_s.window.theme},
          onSelectionChanged: (v) => _setTheme(v.first),
          showSelectedIcon: false,
        ),
      ),
      _row(
        'Сплошной фон',
        'Отключает Mica/прозрачность (для слабых GPU и RDP)',
        _switch(
          _s.window.solidMode,
          (v) => setState(() => _s = _copyWindow(solid: v)),
        ),
      ),
      _sectionLabel('ИКОНКИ'),
      _row(
        'Файлы',
        'Цветные по типу (как в WinSCP) или одноцветные',
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'colored',
              label: Text('Цветные'),
              icon: Icon(Icons.palette_outlined, size: 15),
            ),
            ButtonSegment(
              value: 'mono',
              label: Text('Моно'),
              icon: Icon(Icons.format_color_reset_outlined, size: 15),
            ),
          ],
          selected: {a.fileIcons},
          onSelectionChanged: (v) =>
              _previewAppearance(_copyAppearance(fileIcons: v.first)),
          showSelectedIcon: false,
        ),
      ),
      _row(
        'Папки',
        'Залитые или контурные',
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'filled',
              label: Text('Залитые'),
              icon: Icon(Icons.folder, size: 15),
            ),
            ButtonSegment(
              value: 'outline',
              label: Text('Контур'),
              icon: Icon(Icons.folder_outlined, size: 15),
            ),
          ],
          selected: {a.folderIcons},
          onSelectionChanged: (v) =>
              _previewAppearance(_copyAppearance(folderIcons: v.first)),
          showSelectedIcon: false,
        ),
      ),
      _sectionLabel('ШРИФТЫ'),
      _row(
        'Интерфейс',
        'Системный — шрифт Windows',
        _fontPicker(
          value: a.uiFont,
          families: _uiFonts,
          onChanged: (v) => _previewAppearance(_copyAppearance(uiFont: v)),
        ),
      ),
      _row(
        'Моноширинный',
        'Терминал, редактор, размеры файлов',
        _fontPicker(
          value: a.monoFont,
          families: _monoFonts,
          onChanged: (v) => _previewAppearance(_copyAppearance(monoFont: v)),
        ),
      ),
      _row(
        'Размер шрифта панелей',
        '${a.panelFontSize} пт',
        SizedBox(
          width: 190,
          child: Slider(
            min: 10,
            max: 16,
            divisions: 6,
            value: a.panelFontSize.clamp(10, 16).toDouble(),
            label: '${a.panelFontSize}',
            onChanged: (v) =>
                _previewAppearance(_copyAppearance(panelFontSize: v.round())),
          ),
        ),
      ),
      _sectionLabel('ЦВЕТА ПАНЕЛЕЙ'),
      _row(
        'Текст',
        'Пусто = цвет темы',
        _swatches(
          current: a.panelText,
          options: _textSwatches,
          onPick: (v) => _previewAppearance(_copyAppearance(panelText: v)),
        ),
      ),
      _row(
        'Фон',
        'Пусто = цвет темы',
        _swatches(
          current: a.panelBackground,
          options: _backgroundSwatches,
          onPick: (v) =>
              _previewAppearance(_copyAppearance(panelBackground: v)),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'Изменения применяются сразу; без «Сохранить» они сбросятся при выходе.',
          style: TextStyle(fontSize: 10.5, color: T.faint),
        ),
      ),
    ]);
  }

  Widget _fontPicker({
    required String value,
    required List<String> families,
    required ValueChanged<String> onChanged,
  }) {
    final options = [
      ...families,
      if (!families.contains(value)) value,
    ];
    return DropdownButton<String>(
      value: value,
      dropdownColor: T.menu,
      underline: const SizedBox.shrink(),
      style: TextStyle(fontSize: 12.5, color: T.text),
      items: [
        for (final family in options)
          DropdownMenuItem(
            value: family,
            child: Text(family.isEmpty ? 'Системный' : family),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Widget _swatches({
    required String current,
    required List<String> options,
    required ValueChanged<String> onPick,
  }) {
    final selected = current.trim().toLowerCase();
    return SizedBox(
      width: 250,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _swatch(
            value: '',
            selected: selected.isEmpty,
            color: T.accent,
            onPick: onPick,
            icon: Icons.auto_awesome,
          ),
          for (final value in options)
            _swatch(
              value: value,
              selected: selected == value.toLowerCase(),
              color: _colorOf(value),
              onPick: onPick,
            ),
        ],
      ),
    );
  }

  Widget _swatch({
    required String value,
    required bool selected,
    required Color color,
    required ValueChanged<String> onPick,
    IconData? icon,
  }) {
    return Tooltip(
      message: value.isEmpty ? 'По теме' : value,
      child: InkWell(
        onTap: () => onPick(value),
        customBorder: const CircleBorder(),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: value.isEmpty ? T.panel : color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? T.accent : T.borderStrong,
              width: selected ? 2 : 1,
            ),
          ),
          child: icon == null ? null : Icon(icon, size: 12, color: T.accent),
        ),
      ),
    );
  }

  Widget _panels() {
    return _card('ПАНЕЛИ', [
      _row(
        'Показывать скрытые файлы',
        '',
        _switch(
          _s.panels.showHidden,
          (v) => setState(() => _s = _copyPanels(showHidden: v)),
        ),
      ),
    ]);
  }

  Widget _editor() {
    return _card('РЕДАКТОР (F3 / F4)', [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: NovaField(
                controller: _editorPath,
                label: 'Внешний редактор',
                hint: 'пусто = встроенный · F3 — просмотр, F4 — правка',
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: GhostButton(
                label: 'Выбрать',
                icon: Icons.folder_open_outlined,
                onPressed: () async {
                  final path = await _pickFile(
                    extensions: const ['exe'],
                    label: 'Программы',
                  );
                  if (path != null) {
                    setState(() {
                      _editorPath.text = path;
                      _editorCheck = null;
                    });
                  }
                },
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: GhostButton(
                label: 'Встроенный',
                icon: Icons.code,
                onPressed: () => setState(() {
                  _editorPath.text = '';
                  _editorCheck = null;
                }),
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: GhostButton(
                label: 'Проверить',
                icon: Icons.fact_check_outlined,
                onPressed: () async {
                  final value = _editorPath.text.trim();
                  if (value.isEmpty) {
                    setState(
                      () => _editorCheck = 'будет использован встроенный',
                    );
                    return;
                  }
                  final exists = await pathExists(path: value);
                  setState(
                    () => _editorCheck = exists
                        ? 'файл найден'
                        : 'файл не найден',
                  );
                },
              ),
            ),
          ],
        ),
      ),
      if (_editorCheck != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 6, left: 2),
          child: Row(
            children: [
              Icon(
                _editorCheck == 'файл не найден'
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
                size: 13,
                color: _editorCheck == 'файл не найден' ? T.error : T.success,
              ),
              const SizedBox(width: 6),
              Text(_editorCheck!, style: TextStyle(fontSize: 11, color: T.dim)),
            ],
          ),
        ),
      _row(
        'Если редактор недоступен',
        'Открывать встроенный с подсветкой',
        _switch(
          _s.editor.fallbackBuiltin,
          (v) => setState(() => _s = _copyEditor(fallback: v)),
        ),
      ),
    ]);
  }

  Widget _editLogCard() {
    return _card('ЖУРНАЛ РЕДАКТИРОВАНИЯ', [
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: _log.editLog,
        onChanged: _setEditLog,
        title: const Text(
          'Записывать логи в папку logs',
          style: TextStyle(fontSize: 12.5),
        ),
        subtitle: Text(
          'применяется сразу',
          style: TextStyle(fontSize: 11, color: T.faint),
        ),
      ),
      Text(
        'При включении каждое открытие и сохранение файла пишется в '
        'logs/<сервер>_ДД-ММ-ГГГГ.log: дата, время, сервер и путь к файлу. '
        'У каждого сервера и дня свой файл, старые записи не удаляются.',
        style: TextStyle(fontSize: 11.5, color: T.faint, height: 1.4),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: GhostButton(
          label: 'Открыть журнал',
          icon: Icons.receipt_long,
          onPressed: () =>
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const LogsPage())),
        ),
      ),
    ]);
  }

  Widget _terminal() {
    final profiles = _s.terminal.profiles;
    final selected = _s.terminal.defaultProfile ?? '';
    final active = profiles.where((p) => p.id == selected).firstOrNull;
    return _card('ТЕРМИНАЛ', [
      Text(
        'По умолчанию можно выбрать любой профиль, включая wt.exe, или '
        'встроенный терминал. Команду из PATH (например wt.exe) можно вписать '
        'в поле ниже.',
        style: TextStyle(fontSize: 11.5, color: T.faint, height: 1.4),
      ),
      const SizedBox(height: 10),
      _row(
        'Открывать по умолчанию',
        'F4 / кнопка «Терминал»',
        SizedBox(
          width: 250,
          child: DropdownButton<String>(
            value: selected,
            isExpanded: true,
            dropdownColor: T.menu,
            style: TextStyle(fontSize: 12.5, color: T.text),
            items: [
              const DropdownMenuItem(
                value: '',
                child: Text('Встроенный терминал'),
              ),
              for (final p in profiles)
                DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: (v) => setState(() {
              final value = v ?? '';
              _s = _copyTerminal(value);
              _terminalCmd.text =
                  profiles.where((p) => p.id == value).firstOrNull?.command ??
                  '';
            }),
          ),
        ),
      ),
      const SizedBox(height: 4),
      if (active != null) ...[
        _pathField(
          controller: _terminalCmd,
          label: 'Программа терминала (${active.name})',
          hint: 'пусто = встроенный терминал',
          extensions: const ['exe'],
          pickerLabel: 'Терминал',
        ),
        const SizedBox(height: 4),
        Text(
          'Аргументы: ${active.args.join(' ')}',
          style: TextStyle(
            fontSize: 10,
            color: T.faint,
            fontFamily: T.monoFont,
          ),
        ),
      ] else
        Text(
          'Встроенный терминал — вкладка с оболочкой внутри программы.',
          style: TextStyle(fontSize: 11.5, color: T.dim),
        ),
      const SizedBox(height: 8),
      Text(
        'Профили: ${profiles.map((p) => p.name).join(', ')}',
        style: TextStyle(fontSize: 10.5, color: T.faint),
      ),
    ]);
  }

  Settings _copyTerminal(String defaultProfile) => Settings(
    version: 1,
    locale: _s.locale,
    keymapPreset: _s.keymapPreset,
    appearance: _s.appearance,
    panels: _s.panels,
    transfer: _s.transfer,
    editor: _s.editor,
    terminal: TerminalSettings(
      profiles: _s.terminal.profiles,
      defaultProfile: defaultProfile.isEmpty ? null : defaultProfile,
      androidMode: _s.terminal.androidMode,
      builtinXterm: _s.terminal.builtinXterm,
    ),
    security: _s.security,
    window: _s.window,
  );

  Widget _snippetsCard() {
    return _card('СНИППЕТЫ', [
      Text(
        'Сохранённые команды доступны в терминале: лента избранного над '
        'строкой ввода, кнопка со списком и ✨ для запроса к ИИ. По умолчанию '
        'сниппет только вставляется — «выполнять сразу» включается отдельно.',
        style: TextStyle(fontSize: 11.5, color: T.faint, height: 1.4),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          GhostButton(
            label: 'Добавить сниппет',
            icon: Icons.add,
            onPressed: _newSnippet,
          ),
          const SizedBox(width: 8),
          GhostButton(
            label: 'Обновить',
            icon: Icons.refresh,
            onPressed: _loadSnippets,
          ),
        ],
      ),
      const SizedBox(height: 8),
      if (_snippetsLoading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_snippets.isEmpty)
        Text(
          'Пока пусто. Сниппет можно создать здесь, из терминала («＋») или '
          'сохранить ответ ИИ.',
          style: TextStyle(fontSize: 12, color: T.dim, height: 1.4),
        )
      else
        for (var i = 0; i < _snippets.length; i++) _snippetRow(_snippets[i], i),
    ]);
  }

  Widget _snippetRow(Snippet snippet, int index) {
    final scoped = snippet.scope == 'server' && snippet.serverId != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(6, 2, 2, 2),
      decoration: BoxDecoration(
        color: T.panelSubtle,
        borderRadius: BorderRadius.circular(T.radiusSmall),
        border: Border.all(color: T.border),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: snippet.favorite ? 'Убрать из избранного' : 'В избранное',
            icon: Icon(
              snippet.favorite ? Icons.star : Icons.star_border,
              size: 17,
              color: snippet.favorite ? T.accent : T.dim,
            ),
            onPressed: () => _toggleSnippetFavorite(snippet),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        snippet.name,
                        style: TextStyle(fontSize: 12.5, color: T.text),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (scoped) ...[
                      const SizedBox(width: 6),
                      Text(
                        'этот сервер',
                        style: TextStyle(fontSize: 9.5, color: T.faint),
                      ),
                    ],
                    if (snippet.runImmediately) ...[
                      const SizedBox(width: 6),
                      Text(
                        'выполнять',
                        style: TextStyle(fontSize: 9.5, color: T.accent),
                      ),
                    ],
                  ],
                ),
                Text(
                  snippet.command.replaceAll('\n', ' ↵ '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: T.monoFont,
                    color: T.faint,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Выше',
            icon: Icon(Icons.keyboard_arrow_up, size: 17, color: T.dim),
            onPressed: index == 0 ? null : () => _moveSnippet(index, -1),
          ),
          IconButton(
            tooltip: 'Ниже',
            icon: Icon(Icons.keyboard_arrow_down, size: 17, color: T.dim),
            onPressed: index == _snippets.length - 1
                ? null
                : () => _moveSnippet(index, 1),
          ),
          IconButton(
            tooltip: 'Изменить',
            icon: Icon(Icons.edit_outlined, size: 16, color: T.dim),
            onPressed: () => _editSnippet(snippet),
          ),
          IconButton(
            tooltip: 'Удалить',
            icon: Icon(Icons.delete_outline, size: 16, color: T.error),
            onPressed: () => _removeSnippet(snippet),
          ),
        ],
      ),
    );
  }

  Future<void> _newSnippet() async {
    final saved = await showSnippetEditor(context);
    if (saved == null) return;
    await _loadSnippets();
  }

  Future<void> _editSnippet(Snippet snippet) async {
    final saved = await showSnippetEditor(context, snippet: snippet);
    if (saved == null) return;
    await _loadSnippets();
  }

  Future<void> _toggleSnippetFavorite(Snippet snippet) async {
    try {
      await saveSnippet(
        snippet: Snippet(
          id: snippet.id,
          name: snippet.name,
          command: snippet.command,
          description: snippet.description,
          favorite: !snippet.favorite,
          runImmediately: snippet.runImmediately,
          confirm: snippet.confirm,
          scope: snippet.scope,
          serverId: snippet.serverId,
          order: snippet.order,
          createdAt: snippet.createdAt,
          updatedAt: snippet.updatedAt,
        ),
      );
      await _loadSnippets();
    } catch (e) {
      _syncToast('Сниппет: ${friendlyError(e)}', warn: true);
    }
  }

  Future<void> _removeSnippet(Snippet snippet) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.menu,
        title: const Text('Удалить сниппет?', style: TextStyle(fontSize: 14)),
        content: Text(
          '«${snippet.name}» будет удалён из профиля.',
          style: const TextStyle(fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await deleteSnippet(id: snippet.id);
    await _loadSnippets();
  }

  Future<void> _moveSnippet(int index, int delta) async {
    final next = index + delta;
    if (next < 0 || next >= _snippets.length) return;
    final list = [..._snippets];
    final item = list.removeAt(index);
    list.insert(next, item);
    setState(() => _snippets = list);
    await saveSnippetOrder(ids: [for (final s in list) s.id]);
  }

  Widget _aiCard() {
    final ai = _ai;
    if (ai == null) {
      return _card('ИИ-ПОМОЩНИК', [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()),
        ),
      ]);
    }
    final currentModel = _aiModel.text.trim();
    final modelItems = <String>{
      for (final m in _models) m.id,
      if (currentModel.isNotEmpty) currentModel,
    }.toList()..sort();
    return _card('ИИ-ПОМОЩНИК', [
      Text(
        'Помощник показывает команду для задачи на сервере — и ничего не '
        'выполняет сам. Модели не заданы жёстко: список берётся у провайдера '
        'по /models. Ключ хранится в зашифрованном хранилище.',
        style: TextStyle(fontSize: 11.5, color: T.faint, height: 1.4),
      ),
      const SizedBox(height: 10),
      _row(
        'Провайдер',
        '',
        SizedBox(
          width: 250,
          child: DropdownButton<String>(
            value: ai.provider,
            isExpanded: true,
            dropdownColor: T.menu,
            style: TextStyle(fontSize: 12.5, color: T.text),
            items: [
              for (final entry in aiProviders.entries)
                DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value.label),
                ),
            ],
            onChanged: (v) {
              if (v != null && v != ai.provider) _pickProvider(v);
            },
          ),
        ),
      ),
      const SizedBox(height: 8),
      NovaField(
        controller: _aiEndpoint,
        label: 'Endpoint',
        hint: 'https://opencode.ai/zen/v1',
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _aiKey,
        obscureText: !_aiKeyVisible,
        autocorrect: false,
        enableSuggestions: false,
        style: TextStyle(fontFamily: T.monoFont, fontSize: 12),
        decoration: InputDecoration(
          labelText: 'API-ключ',
          hintText: 'хранится в secrets.json',
          suffixIcon: IconButton(
            tooltip: _aiKeyVisible ? 'Скрыть' : 'Показать',
            icon: Icon(
              _aiKeyVisible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 16,
              color: T.dim,
            ),
            onPressed: () => setState(() => _aiKeyVisible = !_aiKeyVisible),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: DropdownButton<String>(
              value: currentModel.isEmpty ? null : currentModel,
              isExpanded: true,
              hint: Text(
                _models.isEmpty ? 'Модель не выбрана' : 'Выберите модель',
                style: TextStyle(fontSize: 12.5, color: T.faint),
              ),
              dropdownColor: T.menu,
              style: TextStyle(fontSize: 12.5, color: T.text),
              items: [
                for (final id in modelItems)
                  DropdownMenuItem(value: id, child: Text(id)),
              ],
              onChanged: (v) => setState(() {
                _aiModel.text = v ?? '';
              }),
            ),
          ),
          const SizedBox(width: 8),
          GhostButton(
            label: _aiBusy ? '…' : 'Загрузить модели',
            icon: Icons.cloud_download_outlined,
            onPressed: _aiBusy ? null : _fetchModels,
          ),
        ],
      ),
      const SizedBox(height: 8),
      NovaField(
        controller: _aiModel,
        label: 'Модель (можно вписать вручную)',
        hint: 'например deepseek-v4.1-flash',
      ),
      const SizedBox(height: 4),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: ai.enabled,
        onChanged: (v) => setState(() {
          _ai = AiSettings(
            enabled: v,
            provider: ai.provider,
            endpoint: _aiEndpoint.text,
            model: _aiModel.text,
            includeContext: ai.includeContext,
          );
        }),
        title: const Text(
          'Показывать помощника в терминале',
          style: TextStyle(fontSize: 12.5),
        ),
      ),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: ai.includeContext,
        onChanged: (v) => setState(() {
          _ai = AiSettings(
            enabled: ai.enabled,
            provider: ai.provider,
            endpoint: _aiEndpoint.text,
            model: _aiModel.text,
            includeContext: v,
          );
        }),
        title: const Text(
          'Передавать контекст сервера',
          style: TextStyle(fontSize: 12.5),
        ),
        subtitle: Text(
          'хост, пользователь, каталог и версия системы — чтобы команда была '
          'по делу',
          style: TextStyle(fontSize: 11, color: T.faint),
        ),
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          GhostButton(
            label: _aiBusy ? 'Проверяю…' : 'Проверить',
            icon: Icons.check_circle_outline,
            onPressed: _aiBusy ? null : _fetchModels,
          ),
          const SizedBox(width: 8),
          GhostButton(
            label: 'Удалить ключ',
            icon: Icons.key_off_outlined,
            onPressed: _aiBusy
                ? null
                : () => setState(() {
                    _aiKey.clear();
                    _aiStatus = 'Ключ будет удалён после «Сохранить»';
                    _aiStatusError = false;
                  }),
          ),
        ],
      ),
      if (_aiStatus != null) ...[
        const SizedBox(height: 8),
        Text(
          _aiStatus!,
          style: TextStyle(
            fontSize: 11.5,
            color: _aiStatusError ? T.error : T.dim,
            height: 1.4,
          ),
        ),
      ],
      if (_models.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(
          'Доступно моделей: ${_models.length}',
          style: TextStyle(fontSize: 10.5, color: T.faint),
        ),
      ],
    ]);
  }

  Widget _transfer() {
    return _card('ПЕРЕДАЧИ', [
      _row(
        'Параллельных передач',
        '',
        SizedBox(
          width: 120,
          child: DropdownButton<int>(
            value: _s.transfer.concurrency,
            isExpanded: true,
            dropdownColor: T.menu,
            style: TextStyle(fontSize: 12.5, color: T.text),
            items: const [1, 2, 3, 4, 6]
                .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                .toList(),
            onChanged: (v) =>
                setState(() => _s = _copyTransfer(concurrency: v ?? 3)),
          ),
        ),
      ),
      _row(
        'Потоков на один файл',
        'файлы больше 8 МБ режутся на части; на быстрой локальной сети '
            'быстрее 1 поток',
        SizedBox(
          width: 120,
          child: DropdownButton<int>(
            value: _s.transfer.chunksPerFile.clamp(1, 8),
            isExpanded: true,
            dropdownColor: T.menu,
            style: TextStyle(fontSize: 12.5, color: T.text),
            items: const [1, 2, 3, 4, 6, 8]
                .map((v) => DropdownMenuItem(value: v, child: Text('$v')))
                .toList(),
            onChanged: (v) => setState(() => _s = _copyTransfer(parts: v ?? 4)),
          ),
        ),
      ),
      _row(
        'Конфликты при копировании',
        '',
        SizedBox(
          width: 210,
          child: DropdownButton<String>(
            value: _s.transfer.conflictPolicy,
            isExpanded: true,
            dropdownColor: T.menu,
            style: TextStyle(fontSize: 12.5, color: T.text),
            items: const [
              DropdownMenuItem(value: 'ask', child: Text('Спрашивать')),
              DropdownMenuItem(
                value: 'overwrite',
                child: Text('Перезаписывать'),
              ),
              DropdownMenuItem(value: 'skip', child: Text('Пропускать')),
              DropdownMenuItem(value: 'rename', child: Text('Переименовывать')),
            ],
            onChanged: (v) =>
                setState(() => _s = _copyTransfer(policy: v ?? 'ask')),
          ),
        ),
      ),
      _row(
        'Лимит скорости',
        '0 — без ограничения',
        SizedBox(
          width: 180,
          child: DropdownButton<int>(
            value: _s.transfer.bandwidthLimitKibps,
            isExpanded: true,
            dropdownColor: T.menu,
            style: TextStyle(fontSize: 12.5, color: T.text),
            items: const [0, 128, 256, 512, 1024, 2048, 4096]
                .map(
                  (v) => DropdownMenuItem(
                    value: v,
                    child: Text(v == 0 ? 'без лимита' : '$v КБ/с'),
                  ),
                )
                .toList(),
            onChanged: (v) =>
                setState(() => _s = _copyTransfer(bandwidth: v ?? 0)),
          ),
        ),
      ),
      _row(
        'Проверять SHA-256 после копирования',
        'читает файл повторно, поэтому выключено по умолчанию',
        _switch(
          _s.transfer.verifyChecksum != 'off',
          (v) =>
              setState(() => _s = _copyTransfer(verify: v ? 'sha256' : 'off')),
        ),
      ),
    ]);
  }

  /// Android only: the PIN is the vault password on a phone.
  Widget _security() {
    return _card('БЕЗОПАСНОСТЬ', [
      _row(
        'Вход в хранилище',
        'PIN из 4 цифр',
        GhostButton(
          label: 'Сменить PIN',
          icon: Icons.pin_outlined,
          onPressed: _changePin,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        'PIN шифрует пароли серверов. Восстановить его нельзя — если забыли, '
        'серверы придётся добавить заново.',
        style: TextStyle(fontSize: 11.5, color: T.faint, height: 1.4),
      ),
    ]);
  }

  Widget _colors() {
    return _card('ЦВЕТА ФАЙЛОВ', [
      for (var i = 0; i < _rules.length; i++) _ruleRow(i),
      const SizedBox(height: 4),
      Align(
        alignment: Alignment.centerLeft,
        child: GhostButton(
          label: 'Добавить правило',
          icon: Icons.add,
          onPressed: _addRule,
        ),
      ),
    ]);
  }

  Widget _ruleRow(int index) {
    final rule = _rules[index];
    final color = _colorOf(rule.fg);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${rule.name}  ·  ${rule.pattern}',
              style: TextStyle(
                fontSize: 12,
                color: rule.enabled ? color : T.faint,
                fontFamily: T.monoFont,
              ),
            ),
          ),
          Text(
            rule.scope == 'both'
                ? 'везде'
                : rule.scope == 'remote'
                ? 'сервер'
                : 'локально',
            style: TextStyle(fontSize: 10.5, color: T.faint),
          ),
          const SizedBox(width: 8),
          _switch(rule.enabled, (v) {
            setState(
              () => _rules[index] = ColorRule(
                id: rule.id,
                name: rule.name,
                enabled: v,
                priority: rule.priority,
                scope: rule.scope,
                pattern: rule.pattern,
                isRegex: rule.isRegex,
                fg: rule.fg,
                bg: rule.bg,
                bold: rule.bold,
                italic: rule.italic,
                underline: rule.underline,
              ),
            );
          }),
          IconButton(
            icon: const Icon(Icons.close, size: 14),
            color: T.faint,
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _rules.removeAt(index)),
          ),
        ],
      ),
    );
  }

  Future<void> _addRule() async {
    final name = TextEditingController(text: 'Новое правило');
    final pattern = TextEditingController(text: '*.log');
    var scope = 'both';
    var color = '#FF7B72';

    final created = await showDialog<ColorRule>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Правило подсветки'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NovaField(controller: name, label: 'Название', autofocus: true),
                const SizedBox(height: 10),
                NovaField(
                  controller: pattern,
                  label: 'Маска или регулярка',
                  hint: '*.php',
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: scope,
                        decoration: const InputDecoration(labelText: 'Где'),
                        dropdownColor: T.menu,
                        items: const [
                          DropdownMenuItem(value: 'both', child: Text('Везде')),
                          DropdownMenuItem(
                            value: 'local',
                            child: Text('Локально'),
                          ),
                          DropdownMenuItem(
                            value: 'remote',
                            child: Text('На сервере'),
                          ),
                        ],
                        onChanged: (v) => setLocal(() => scope = v ?? 'both'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: color,
                        decoration: const InputDecoration(labelText: 'Цвет'),
                        dropdownColor: T.menu,
                        items:
                            const [
                                  ('#FF7B72', 'Красный'),
                                  ('#D2A8FF', 'Фиолетовый'),
                                  ('#7EE787', 'Зелёный'),
                                  ('#79C0FF', 'Синий'),
                                  ('#FFA657', 'Оранжевый'),
                                  ('#E3B341', 'Жёлтый'),
                                ]
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e.$1,
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 10,
                                          height: 10,
                                          decoration: BoxDecoration(
                                            color: _colorOf(e.$1),
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          e.$2,
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                        onChanged: (v) =>
                            setLocal(() => color = v ?? '#FF7B72'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                ctx,
                ColorRule(
                  id: 'r_${DateTime.now().microsecondsSinceEpoch}',
                  name: name.text.trim().isEmpty ? 'Правило' : name.text.trim(),
                  enabled: true,
                  priority: 50,
                  scope: scope,
                  pattern: pattern.text.trim().isEmpty
                      ? '*'
                      : pattern.text.trim(),
                  isRegex: false,
                  fg: color,
                  bg: null,
                  bold: false,
                  italic: false,
                  underline: false,
                ),
              ),
              child: const Text('Добавить'),
            ),
          ],
        ),
      ),
    );
    if (created != null) setState(() => _rules.add(created));
  }

  Widget _importCard() {
    return _card('ИМПОРТ ИЗ WINSCP', [
      Row(
        children: [
          Expanded(
            flex: 3,
            child: _pathField(
              controller: _winscpIni,
              label: 'WinSCP.ini',
              extensions: const ['ini'],
              pickerLabel: 'Конфигурация WinSCP',
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: GhostButton(
          label: 'Импортировать серверы и группы',
          icon: Icons.download_outlined,
          onPressed: _importWinscp,
        ),
      ),
    ]);
  }

  /// Opens the system picker and returns the chosen path.
  Future<String?> _pickFile({
    List<String>? extensions,
    String label = 'Файлы',
  }) async {
    try {
      final group = XTypeGroup(label: label, extensions: extensions);
      final file = await openFile(acceptedTypeGroups: [group]);
      return file?.path;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: T.raised,
            behavior: SnackBarBehavior.floating,
            width: 420,
            content: Text(
              'Не удалось открыть выбор файла: $e',
              style: TextStyle(fontSize: 12.5, color: T.error),
            ),
          ),
        );
      }
      return null;
    }
  }

  /// A text field with a "choose file" button.
  Widget _pathField({
    required TextEditingController controller,
    required String label,
    String? hint,
    List<String>? extensions,
    String pickerLabel = 'Файлы',
  }) {
    return Row(
      children: [
        Expanded(
          child: NovaField(controller: controller, label: label, hint: hint),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: GhostButton(
            label: 'Выбрать',
            icon: Icons.folder_open_outlined,
            onPressed: () async {
              final path = await _pickFile(
                extensions: extensions,
                label: pickerLabel,
              );
              if (path != null) setState(() => controller.text = path);
            },
          ),
        ),
      ],
    );
  }

  Future<void> _importWinscp() async {
    final ini = _winscpIni.text.trim();
    try {
      final report = await importWinscpIni(iniPath: ini);
      await widget.nova.reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: T.raised,
          behavior: SnackBarBehavior.floating,
          width: 560,
          content: Text(
            'Импорт: ${report.imported} серверов, ${report.groups} групп, '
            '${report.passwords} паролей, пропущено ${report.skipped}',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: T.raised,
          behavior: SnackBarBehavior.floating,
          width: 560,
          content: Text('$e', style: TextStyle(fontSize: 12.5, color: T.error)),
        ),
      );
    }
  }

  Widget _about() {
    final info = widget.nova.info;
    return _card('О ПРОГРАММЕ', [
      _row('Версия', info?.version ?? '—', Text('')),
      _row('Данные', info?.dataDir ?? '—', Text('')),
      _row('Платформа', info?.platform ?? '—', Text('')),
      Align(
        alignment: Alignment.centerLeft,
        child: GhostButton(
          label: 'Журнал событий',
          icon: Icons.receipt_long,
          onPressed: () =>
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const LogsPage())),
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: GhostButton(
          label: 'Скопировать путь данных',
          icon: Icons.copy,
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(info?.dataDir ?? ''),
                backgroundColor: T.raised,
                behavior: SnackBarBehavior.floating,
                width: 460,
              ),
            );
          },
        ),
      ),
    ]);
  }

  // ------------------------------------------------------------- copy helpers

  /// Applies the appearance tab immediately (fonts, icons, colours) and keeps
  /// the value in `_s` so "Сохранить" can persist it.
  void _previewAppearance(Settings next) {
    setState(() => _s = next);
    widget.nova.previewAppearance(next.appearance);
  }

  Settings _copyAppearance({
    String? fileIcons,
    String? folderIcons,
    String? uiFont,
    String? monoFont,
    int? panelFontSize,
    String? panelText,
    String? panelBackground,
  }) => Settings(
    version: 1,
    locale: _s.locale,
    keymapPreset: _s.keymapPreset,
    appearance: AppearanceSettings(
      fileIcons: fileIcons ?? _s.appearance.fileIcons,
      folderIcons: folderIcons ?? _s.appearance.folderIcons,
      uiFont: uiFont ?? _s.appearance.uiFont,
      monoFont: monoFont ?? _s.appearance.monoFont,
      panelFontSize: panelFontSize ?? _s.appearance.panelFontSize,
      panelText: panelText ?? _s.appearance.panelText,
      panelBackground: panelBackground ?? _s.appearance.panelBackground,
    ),
    panels: _s.panels,
    transfer: _s.transfer,
    editor: _s.editor,
    terminal: _s.terminal,
    security: _s.security,
    window: _s.window,
  );

  Settings _copyWindow({bool? solid, String? theme}) => Settings(
    version: 1,
    locale: _s.locale,
    keymapPreset: _s.keymapPreset,
    appearance: _s.appearance,
    panels: _s.panels,
    transfer: _s.transfer,
    editor: _s.editor,
    terminal: _s.terminal,
    security: _s.security,
    window: WindowSettings(
      backdrop: _s.window.backdrop,
      solidMode: solid ?? _s.window.solidMode,
      restoreBounds: _s.window.restoreBounds,
      theme: theme ?? _s.window.theme,
    ),
  );

  Settings _copyPanels({
    bool? showHidden,
    bool? sync,
    bool? compare,
    bool? tabs,
    bool? filter,
    String? rowDensity,
  }) => Settings(
    version: 1,
    locale: _s.locale,
    keymapPreset: _s.keymapPreset,
    appearance: _s.appearance,
    panels: PanelSettings(
      layout: _s.panels.layout,
      showHidden: showHidden ?? _s.panels.showHidden,
      rowDensity: rowDensity ?? _s.panels.rowDensity,
      syncNavigation: sync ?? _s.panels.syncNavigation,
      comparePanels: compare ?? _s.panels.comparePanels,
      tabsEnabled: tabs ?? _s.panels.tabsEnabled,
      quickFilter: filter ?? _s.panels.quickFilter,
      localBookmarks: _s.panels.localBookmarks,
      remoteBookmarks: _s.panels.remoteBookmarks,
    ),
    transfer: _s.transfer,
    editor: _s.editor,
    terminal: _s.terminal,
    security: _s.security,
    window: _s.window,
  );

  Settings _copyEditor({bool? fallback}) => Settings(
    version: 1,
    locale: _s.locale,
    keymapPreset: _s.keymapPreset,
    appearance: _s.appearance,
    panels: _s.panels,
    transfer: _s.transfer,
    editor: EditorSettings(
      external_: _s.editor.external_,
      fallbackBuiltin: fallback ?? _s.editor.fallbackBuiltin,
    ),
    terminal: _s.terminal,
    security: _s.security,
    window: _s.window,
  );

  Settings _copyTransfer({
    int? concurrency,
    int? parts,
    String? policy,
    int? bandwidth,
    String? verify,
  }) => Settings(
    version: 1,
    locale: _s.locale,
    keymapPreset: _s.keymapPreset,
    appearance: _s.appearance,
    panels: _s.panels,
    transfer: TransferSettings(
      concurrency: concurrency ?? _s.transfer.concurrency,
      chunksPerFile: parts ?? _s.transfer.chunksPerFile,
      chunkKib: _s.transfer.chunkKib,
      bandwidthLimitKibps: bandwidth ?? _s.transfer.bandwidthLimitKibps,
      conflictPolicy: policy ?? _s.transfer.conflictPolicy,
      verifyChecksum: verify ?? _s.transfer.verifyChecksum,
      preserveTimes: _s.transfer.preserveTimes,
      resume: _s.transfer.resume,
    ),
    editor: _s.editor,
    terminal: _s.terminal,
    security: _s.security,
    window: _s.window,
  );

  Color _colorOf(String? hex) {
    if (hex == null) return T.text;
    final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
    if (value == null) return T.text;
    return Color(0xFF000000 | value);
  }
}
