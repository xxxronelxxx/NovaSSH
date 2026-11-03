import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// Opaque-enough content surface with a 1px hairline border.
class NovaSurface extends StatelessWidget {
  NovaSurface({
    super.key,
    required this.child,
    this.color,
    this.radius = T.radius,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final Color? color;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? T.panel,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: T.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class ToolButton extends StatefulWidget {
  const ToolButton({
    super.key,
    required this.icon,
    this.tooltip,
    this.onPressed,
    this.enabled = true,
    this.accent = false,
  });

  final IconData icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool enabled;
  final bool accent;

  @override
  State<ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && widget.onPressed != null;
    final color = !enabled
        ? T.faint.withValues(alpha: 0.5)
        : widget.accent
        ? T.accent
        : T.text;

    final button = MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: enabled ? widget.onPressed : null,
          child: AnimatedContainer(
            duration: Duration(milliseconds: 120),
            width: 32,
            height: 30,
            decoration: BoxDecoration(
              color: _hover && enabled
                  ? (widget.accent ? T.accent.withValues(alpha: 0.18) : T.hover)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(T.radiusSmall),
            ),
            child: Icon(widget.icon, size: 17, color: color),
          ),
        ),
      );
    // Tooltips need an Overlay; the custom caption is built above the Navigator,
    // so it passes no tooltip and gets the bare button instead.
    if (widget.tooltip == null) return button;
    return Tooltip(message: widget.tooltip, child: button);
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: T.accent,
        foregroundColor: Colors.white,
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.radiusSmall),
        ),
      ),
      icon: busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : Icon(icon ?? Icons.arrow_forward, size: 17),
      label: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: T.dim,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.radiusSmall),
        ),
      ),
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }
}

class NovaField extends StatelessWidget {
  const NovaField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.obscure = false,
    this.keyboardType,
    this.onSubmitted,
    this.autofocus = false,
    this.suffix,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 2, bottom: 6),
          child: Text(label, style: TextStyle(fontSize: 11.5, color: T.dim)),
        ),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          autofocus: autofocus,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          style: TextStyle(fontSize: 13.5, color: T.text),
          decoration: InputDecoration(hintText: hint, suffixIcon: suffix),
        ),
      ],
    );
  }
}

/// A user-facing dialog for failures (wrong password, host unreachable, ...).
/// Lets Enter press the dialog's primary button and Esc cancel it.
///
/// AlertDialog never focuses its actions by themselves, so a highlighted
/// "Удалить" did nothing on Enter. Dialogs with a text field are unaffected:
/// the field consumes Enter itself (onSubmitted).
class DialogShortcuts extends StatelessWidget {
  const DialogShortcuts({
    super.key,
    required this.onConfirm,
    this.onCancel,
    required this.child,
  });

  final VoidCallback onConfirm;
  final VoidCallback? onCancel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): onConfirm,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): onConfirm,
        if (onCancel != null)
          const SingleActivator(LogicalKeyboardKey.escape): onCancel!,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

Future<void> showErrorDialog(
  BuildContext context, {
  required String message,
  String title = 'Не удалось подключиться',
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => DialogShortcuts(
      onConfirm: () => Navigator.pop(ctx),
      onCancel: () => Navigator.pop(ctx),
      child: AlertDialog(
      title: Row(
        children: [
          Icon(Icons.error_outline, size: 20, color: T.error),
          SizedBox(width: 8),
          Expanded(child: Text(title, style: TextStyle(fontSize: 15))),
        ],
      ),
      insetPadding: const EdgeInsets.all(24),
      contentPadding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
      constraints: const BoxConstraints(maxWidth: 440),
      content: Text(message, style: TextStyle(fontSize: 13, height: 1.45)),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          style: FilledButton.styleFrom(backgroundColor: T.accent),
          child: const Text('Понятно'),
        ),
      ],
      ),
    ),
  );
}

/// True when the server rejected the credentials (as opposed to being offline).
bool isAuthError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('authentication failed') ||
      text.contains('permission denied') ||
      text.contains('publickey, password') ||
      text.contains('auth');
}

/// Maps low-level SSH/IO errors to short, human wording.
String friendlyError(Object error) {
  final raw = error.toString().replaceFirst('Exception: ', '');
  final text = raw.toLowerCase();
  String two(String a, String b) => '$a\n$b';

  if (text.contains('authentication failed') ||
      text.contains('permission denied') ||
      text.contains('auth')) {
    final allows = <String>[];
    if (text.contains('publickey')) allows.add('ключ');
    if (text.contains('password')) allows.add('пароль');
    if (text.contains('keyboard-interactive')) allows.add('клавиатурный ввод');
    final tail = allows.isEmpty
        ? 'Проверьте учётные данные в свойствах сервера.'
        : 'Сервер принимает: ${allows.join(', ')}.\n'
            'Проверьте логин и пароль (или ключ) в свойствах сервера.';
    return two('Сервер отклонил вход.', tail);
  }
  if (text.contains('host key changed') || text.contains('unknown server key')) {
    return two('Ключ сервера изменился.',
        'Если вы не меняли сервер, подключение может быть небезопасным. '
        'Удалите сохранённый ключ в свойствах сервера, чтобы принять новый.');
  }
  if (text.contains('timed out') || text.contains('timeout')) {
    return two('Сервер не ответил вовремя.',
        'Проверьте адрес и порт, а также доступность сети или VPN.');
  }
  if (text.contains('10061') || text.contains('connection refused')) {
    return two('Сервер доступен, но отклоняет подключение.',
        'Возможно, SSH-служба не запущена или порт указан неверно.');
  }
  if (text.contains('10060') ||
      text.contains('unreachable') ||
      text.contains('no route')) {
    return two('Сервер недоступен по сети.',
        'Проверьте адрес, интернет-соединение или VPN.');
  }
  if (text.contains('11001') ||
      text.contains('failed to lookup') ||
      text.contains('name or service not known')) {
    return two('Не удалось найти сервер по имени.',
        'Проверьте написание хоста или укажите IP-адрес.');
  }
  if (text.contains('password is not stored')) {
    return two('Для этого сервера не сохранён пароль.',
        'Откройте свойства сервера и укажите пароль.');
  }
  if (text.contains('editor not found')) {
    return two('Внешний редактор не найден.',
        'Проверьте путь в настройках или выберите файл заново.');
  }
  return raw;
}

String formatBytes(num bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : (value >= 10 ? 1 : 2);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String formatDate(int? millis) {
  if (millis == null || millis == 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

String joinPath(String base, String name) {
  if (name.startsWith('/')) return name;
  final sep = base.contains('\\') && !base.contains('/') ? '\\' : '/';
  final trimmed = base.replaceAll(RegExp(r'[\\/]+$'), '');
  if (trimmed.isEmpty) return base.isEmpty ? name : '$sep$name';
  return '$trimmed$sep$name';
}

String parentPath(String path) {
  final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
  if (trimmed.isEmpty || trimmed == '/' ) return path;
  if (RegExp(r'^[A-Za-z]:$').hasMatch(trimmed)) return '$trimmed\\';
  final idx = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  if (idx <= 0) return trimmed.startsWith('/') ? '/' : '';
  final parent = trimmed.substring(0, idx);
  if (RegExp(r'^[A-Za-z]:$').hasMatch(parent)) return '$parent\\';
  return parent;
}

String fileName(String path) {
  final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
  final idx = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  return idx < 0 ? trimmed : trimmed.substring(idx + 1);
}

/// Same semantics as `glob_match` in the Rust core: `*`, `?`, `{a,b}`.
RegExp? globToRegExp(String pattern) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < pattern.length; i++) {
    final ch = pattern[i];
    switch (ch) {
      case '*':
        buffer.write('.*');
        break;
      case '?':
        buffer.write('.');
        break;
      case '{':
        final end = pattern.indexOf('}', i);
        if (end > i) {
          final parts = pattern.substring(i + 1, end).split(',');
          buffer.write('(?:${parts.map(RegExp.escape).join('|')})');
          i = end;
        } else {
          buffer.write(RegExp.escape(ch));
        }
        break;
      default:
        buffer.write(RegExp.escape(ch));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString(), caseSensitive: false);
}
