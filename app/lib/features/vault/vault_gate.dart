import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/nova.dart';
import '../../bridge/api.dart';
import '../../design/tokens.dart';
import '../../design/ui.dart';

/// Unlock / create screen.
///
/// Windows keeps the master password (Argon2id + DPAPI "remember me"). Android
/// uses a 4-digit PIN instead: the vault is encrypted with the PIN, so there is
/// no long password to type on a phone keyboard.
class VaultGate extends StatefulWidget {
  const VaultGate({super.key, required this.nova});

  final NovaController nova;

  @override
  State<VaultGate> createState() => _VaultGateState();
}

class _VaultGateState extends State<VaultGate> {
  final _password = TextEditingController();
  final _repeat = TextEditingController();

  bool _remember = true;
  bool _busy = false;
  String? _error;

  /// Android: PIN pad by default, password as a fallback for old profiles.
  bool _passwordMode = false;
  String _pin = '';
  String? _firstPin;
  int _attempts = 0;
  DateTime? _lockedUntil;
  Timer? _cooldown;

  bool get _creating => !widget.nova.hasVault;
  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  /// Windows has no master password any more. The password screen is shown
  /// once, only to move an old profile to the DPAPI-protected key.
  bool get _migrating => widget.nova.needsPasswordMigration;

  bool get _pinUi => _isAndroid && !_passwordMode;

  @override
  void dispose() {
    _cooldown?.cancel();
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ password

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_migrating) {
        await widget.nova.migrateToDeviceKey(_password.text);
        return;
      }
      if (_creating) {
        if (_password.text.length < 8) {
          throw 'Пароль короче 8 символов';
        }
        if (_password.text != _repeat.text) {
          throw 'Пароли не совпадают';
        }
        await widget.nova.createVault(_password.text);
      } else {
        await widget.nova.unlock(_password.text);
      }
      if (_remember && !_isAndroid) {
        await widget.nova.rememberDevice();
      }
      // Must happen while this screen still exists: reload() replaces it with
      // the server list.
      if (!_creating && _isAndroid && mounted) {
        await _offerPin(_password.text);
      }
      await widget.nova.reload();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlockDevice() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await widget.nova.unlockWithDevice();
      if (!ok) {
        setState(() => _error = 'Сохранённый ключ не найден');
      } else {
        await widget.nova.reload();
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// After a password unlock on Android, offer to switch to a PIN.
  Future<void> _offerPin(String password) async {
    final want = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.menu,
        title: const Text('Входить по PIN?', style: TextStyle(fontSize: 14)),
        content: const Text(
          'Можно заменить мастер-пароль на 4-значный PIN — так удобнее на телефоне. '
          'PIN будет шифровать хранилище вместо пароля.',
          style: TextStyle(fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Позже'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Задать PIN'),
          ),
        ],
      ),
    );
    if (want != true || !mounted) return;

    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => _PinSetupDialog(),
    );
    if (pin == null || !mounted) return;
    try {
      await changeVaultPassword(oldPassword: password, newPassword: pin);
      _toast('PIN сохранён');
    } catch (e) {
      _toast('Не удалось сменить PIN: $e', warn: true);
    }
  }

  void _toast(String message, {bool warn = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(fontSize: 12.5, color: T.text)),
        backgroundColor: warn ? T.warnSurface : T.panel,
        behavior: SnackBarBehavior.floating,
        width: MediaQuery.sizeOf(context).width - 48 < 380
            ? MediaQuery.sizeOf(context).width - 32
            : 380,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.radiusSmall),
          side: BorderSide(color: T.border),
        ),
      ),
    );
  }

  // ----------------------------------------------------------------------- PIN

  void _tapDigit(String digit) {
    if (_busy) return;
    final until = _lockedUntil;
    if (until != null && DateTime.now().isBefore(until)) return;
    if (_pin.length >= 4) return;
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length == 4) unawaited(_submitPin());
  }

  void _backspace() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submitPin() async {
    final pin = _pin;
    if (_creating) {
      if (_firstPin == null) {
        setState(() {
          _firstPin = pin;
          _pin = '';
        });
        return;
      }
      if (_firstPin != pin) {
        setState(() {
          _firstPin = null;
          _pin = '';
          _error = 'PIN не совпадает — попробуйте снова';
        });
        return;
      }
      await _createWithPin(pin);
      return;
    }
    await _unlockWithPin(pin);
  }

  Future<void> _createWithPin(String pin) async {
    setState(() => _busy = true);
    try {
      await widget.nova.createVault(pin);
      await widget.nova.reload();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _pin = '';
        _firstPin = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlockWithPin(String pin) async {
    setState(() => _busy = true);
    try {
      await widget.nova.unlock(pin);
      await widget.nova.reload();
    } catch (_) {
      _attempts++;
      final tooMany = _attempts >= 5;
      if (tooMany) {
        _lockedUntil = DateTime.now().add(const Duration(seconds: 30));
        _startCooldown();
      }
      setState(() {
        _pin = '';
        _error = tooMany
            ? 'Слишком много попыток. Подождите 30 секунд.'
            : 'Неверный PIN${_attempts > 1 ? ' (попытка $_attempts)' : ''}';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startCooldown() {
    _cooldown?.cancel();
    _cooldown = Timer.periodic(const Duration(seconds: 1), (timer) {
      final until = _lockedUntil;
      if (until == null || DateTime.now().isAfter(until)) {
        timer.cancel();
        if (mounted) {
          setState(() {
            _attempts = 0;
            _lockedUntil = null;
            _error = null;
          });
        }
      } else if (mounted) {
        setState(() {});
      }
    });
  }

  // --------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: NovaSurface(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                const SizedBox(height: 22),
                if (_pinUi) _pinBody() else _passwordBody(),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: T.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.asset('assets/icon.png', width: 38, height: 38),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nova SSH',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            Text(
              'SSH-коммандер',
              style: TextStyle(fontSize: 11.5, color: T.dim),
            ),
          ],
        ),
      ],
    );
  }

  Widget _pinBody() {
    final first = _firstPin != null;
    final title = _creating
        ? (first ? 'Повторите PIN' : 'Придумайте PIN')
        : 'Введите PIN';
    final hint = _creating
        ? '4 цифры. PIN шифрует пароли серверов, восстановить его нельзя.'
        : '4-значный PIN для входа в хранилище.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          hint,
          style: TextStyle(fontSize: 12.5, color: T.dim, height: 1.45),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 4; i++)
              Container(
                width: 16,
                height: 16,
                margin: const EdgeInsets.symmetric(horizontal: 7),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _pin.length ? T.accent : Colors.transparent,
                  border: Border.all(color: T.borderStrong, width: 1.5),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        _pinPad(),
        if (!_creating) ...[
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => setState(() {
              _passwordMode = true;
              _pin = '';
              _error = null;
            }),
            child: const Text(
              'Ввести мастер-пароль',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  Widget _pinPad() {
    final locked =
        _lockedUntil != null && DateTime.now().isBefore(_lockedUntil!);
    Widget key(String? digit, {IconData? icon}) {
      final enabled = !_busy && !locked;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            height: 54,
            child: InkWell(
              onTap: !enabled
                  ? null
                  : digit != null
                  ? () => _tapDigit(digit)
                  : _backspace,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: T.hover,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: T.border),
                ),
                child: icon != null
                    ? Icon(icon, size: 20, color: T.dim)
                    : Text(
                        digit!,
                        style: TextStyle(
                          fontSize: 20,
                          color: enabled ? T.text : T.faint,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(children: [for (final d in row) key(d)]),
        Row(
          children: [
            const Spacer(),
            key('0'),
            key(null, icon: Icons.backspace_outlined),
          ],
        ),
        if (_creating) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _passwordMode = true;
                    _pin = '';
                    _firstPin = null;
                    _error = null;
                  }),
            child: const Text(
              'Использовать длинный пароль',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  Widget _passwordBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _migrating
              ? 'Последний раз вводим пароль'
              : _creating
              ? 'Создайте мастер-пароль'
              : 'Хранилище заблокировано',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          _migrating
              ? (widget.nova.info?.hasDeviceKey ?? false
                    ? 'Ключ устройства не подошёл к этому профилю. Введите '
                          'мастер-пароль — после этого хранилище перейдёт на '
                          'ключ Windows (DPAPI) и пароль больше не понадобится.'
                    : 'В Windows мастер-пароль больше не нужен: после этого '
                          'раза хранилище будет открываться ключом устройства '
                          '(DPAPI).')
              : _creating
              ? 'Он шифрует пароли серверов (Argon2id + AES-256-GCM). '
                    'Восстановить его нельзя — сохраните в надёжном месте.'
              : 'Введите мастер-пароль, чтобы открыть список серверов.',
          style: TextStyle(fontSize: 12.5, color: T.dim, height: 1.45),
        ),
        const SizedBox(height: 20),
        NovaField(
          controller: _password,
          label: 'Мастер-пароль',
          obscure: true,
          autofocus: true,
          onSubmitted: (_) => _submit(),
        ),
        if (_creating) ...[
          const SizedBox(height: 12),
          NovaField(
            controller: _repeat,
            label: 'Повторите пароль',
            obscure: true,
            onSubmitted: (_) => _submit(),
          ),
        ],
        if (_creating && !_isAndroid) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Checkbox(
                value: _remember,
                onChanged: (v) => setState(() => _remember = v ?? true),
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: T.borderStrong),
              ),
              Expanded(
                child: Text(
                  'Запомнить на этом устройстве (DPAPI)',
                  style: TextStyle(fontSize: 12, color: T.dim),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        PrimaryButton(
          label: _migrating
              ? 'Перенести хранилище'
              : _creating
              ? 'Создать хранилище'
              : 'Разблокировать',
          icon: Icons.lock_open,
          busy: _busy,
          onPressed: _submit,
        ),
        if (!_creating && !_isAndroid && !_migrating) ...[
          const SizedBox(height: 8),
          GhostButton(
            label: 'Использовать ключ устройства',
            icon: Icons.fingerprint,
            onPressed: _busy ? null : _unlockDevice,
          ),
        ],
        if (_isAndroid) ...[
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => setState(() {
              _passwordMode = false;
              _error = null;
            }),
            child: const Text(
              'Вернуться к PIN',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}

/// Two-step PIN dialog used when converting an existing password vault.
class _PinSetupDialog extends StatefulWidget {
  @override
  State<_PinSetupDialog> createState() => _PinSetupDialogState();
}

class _PinSetupDialogState extends State<_PinSetupDialog> {
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
    final b = _repeat.text.trim();
    if (a.length != 4 || int.tryParse(a) == null) {
      setState(() => _error = 'Нужно ровно 4 цифры');
      return;
    }
    if (a != b) {
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
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              obscureText: true,
              style: const TextStyle(fontSize: 16, letterSpacing: 6),
              decoration: const InputDecoration(labelText: 'PIN (4 цифры)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _repeat,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              obscureText: true,
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
