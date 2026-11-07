import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../bridge/api.dart';
import '../../design/tokens.dart';
import '../../design/ui.dart';

/// «Профиль» card: everything the program keeps next to itself, plus export
/// and import of servers (with their passwords) and settings.
class ProfileCard extends StatefulWidget {
  const ProfileCard({
    super.key,
    required this.dataDir,
    required this.onImported,
    this.deviceKeyVault = false,
  });

  final String dataDir;

  /// Called after a successful import so the app can reload its state.
  final Future<void> Function() onImported;

  /// Windows: the vault is protected by the DPAPI key, no password exists.
  final bool deviceKeyVault;

  @override
  State<ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<ProfileCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: T.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(T.radius),
        side: BorderSide(color: T.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ПРОФИЛЬ',
              style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.7,
                fontWeight: FontWeight.w600,
                color: T.faint,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.dataDir,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: T.monoFont,
                      color: T.dim,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GhostButton(
                  label: 'Открыть папку',
                  icon: Icons.folder_open,
                  onPressed: () async {
                    try {
                      await Process.start('explorer.exe', [
                        widget.dataDir,
                      ], mode: ProcessStartMode.detached);
                    } catch (_) {}
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Серверы, настройки и пароли хранятся в этой папке рядом с '
              'программой.',
              style: TextStyle(fontSize: 11.5, color: T.faint, height: 1.4),
            ),
            if (widget.deviceKeyVault) ...[
              const SizedBox(height: 4),
              Text(
                'Пароли серверов шифруются ключом этого компьютера (DPAPI) и '
                'открываются вместе с программой — пароль вводить не нужно.',
                style: TextStyle(fontSize: 11.5, color: T.faint, height: 1.4),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                GhostButton(
                  label: _busy ? '…' : 'Экспортировать профиль…',
                  icon: Icons.ios_share,
                  onPressed: _busy ? null : _export,
                ),
                GhostButton(
                  label: 'Импортировать профиль…',
                  icon: Icons.download_outlined,
                  onPressed: _busy ? null : _import,
                ),
                GhostButton(
                  label: 'Пароли (IP:пароль)…',
                  icon: Icons.password_outlined,
                  onPressed: _busy ? null : _credentials,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogShortcuts(
        onConfirm: () => Navigator.pop(ctx, true),
        onCancel: () => Navigator.pop(ctx, false),
        child: AlertDialog(
          backgroundColor: T.menu,
          title: const Text(
            'Экспортировать профиль?',
            style: TextStyle(fontSize: 14),
          ),
          content: const Text(
            'В файл попадут серверы, настройки, сниппеты, сохранённые пароли '
            'и ключи ИИ. Файл не шифруется: храните его в надёжном месте и не '
            'оставляйте в общих папках или облаке.',
            style: TextStyle(fontSize: 12.5, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Экспортировать'),
            ),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    final location = await getSaveLocation(
      suggestedName: 'nova-profile.novaprof',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Профиль NovaSSH', extensions: ['novaprof']),
      ],
    );
    if (location == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await exportProfile(path: location.path);
      _toast('Профиль сохранён: ${location.path}');
    } catch (e) {
      _toast('Экспорт: ${friendlyError(e)}', warn: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Plain `host:port  user  password` list: view it in a window, copy it or
  /// save it to a text file.
  Future<void> _credentials() async {
    setState(() => _busy = true);
    String text;
    try {
      text = await credentialsPreview();
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _toast('Пароли: ${friendlyError(e)}', warn: true);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    final entries = text
        .split('\n')
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .length;
    if (entries == 0) {
      _toast('Нет сохранённых паролей', warn: true);
      return;
    }

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.menu,
        insetPadding: const EdgeInsets.all(24),
        title: const Text(
          'Серверы и пароли',
          style: TextStyle(fontSize: 14),
        ),
        content: SizedBox(
          width: 560,
          height: 360,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Пароли в открытом виде. Не оставляйте окно на виду.',
                style: TextStyle(fontSize: 11, color: T.warn, height: 1.35),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: T.panel,
                    borderRadius: BorderRadius.circular(T.radiusSmall),
                    border: Border.all(color: T.border),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      text,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: T.text,
                        fontFamily: T.monoFont,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Закрыть'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'copy'),
            child: const Text('Копировать'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('В файл…'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;

    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: text));
      _toast('Список скопирован');
      return;
    }

    final location = await getSaveLocation(
      suggestedName: 'nova-passwords.txt',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Текст', extensions: ['txt']),
      ],
    );
    if (location == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final count = await exportCredentials(path: location.path);
      _toast('Сохранено серверов: $count · ${location.path}');
    } catch (e) {
      _toast('Экспорт паролей: ${friendlyError(e)}', warn: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Профиль NovaSSH', extensions: ['novaprof']),
      ],
    );
    if (file == null || !mounted) return;
    final replace = await _askMode();
    if (replace == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final report = await importProfile(path: file.path, replace: replace);
      await widget.onImported();
      if (!mounted) return;
      final parts = <String>[
        if (report.replaced)
          'профиль заменён'
        else
          'добавлено серверов: ${report.servers}',
        'групп: ${report.groups}',
        'сниппетов: ${report.snippets}',
        'паролей: ${report.secrets}',
        if (report.backupDir != null) 'бэкап: ${report.backupDir}',
      ];
      _toast(parts.join(' · '));
    } catch (e) {
      _toast('Импорт: ${friendlyError(e)}', warn: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _askMode() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => DialogShortcuts(
        onConfirm: () => Navigator.pop(ctx, false),
        onCancel: () => Navigator.pop(ctx),
        child: AlertDialog(
          backgroundColor: T.menu,
          title: const Text(
            'Как импортировать?',
            style: TextStyle(fontSize: 14),
          ),
          content: const Text(
            '«Добавить» сохранит текущие серверы и пропустит совпадения '
            '(тот же хост, порт и пользователь). «Заменить» перезапишет профиль '
            'целиком — перед этим рядом с ним создаётся резервная копия.',
            style: TextStyle(fontSize: 12.5, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Заменить всё'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Добавить'),
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String text, {bool warn = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: warn ? T.error : T.menu,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }
}
