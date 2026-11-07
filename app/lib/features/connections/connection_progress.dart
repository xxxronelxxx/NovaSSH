import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../bridge/api.dart';
import '../../bridge/model.dart';
import '../../design/tokens.dart';

/// Result of the connection attempt, driving how the checklist is rendered.
enum ConnectionOutcome { pending, success, failure }

/// WinSCP-style connection progress window.
///
/// The transport reports only two real milestones (dialling and SFTP ready), so
/// the intermediate steps advance on a short timer: the goal is to show that
/// something is happening and on which stage, not to fake exact telemetry.
class ConnectionProgressDialog extends StatefulWidget {
  const ConnectionProgressDialog({
    super.key,
    required this.server,
    required this.outcome,
    this.onCancel,
  });

  final Server server;
  final ValueListenable<ConnectionOutcome> outcome;

  /// Stops the attempt. Only offered while the outcome is still pending.
  final VoidCallback? onCancel;

  @override
  State<ConnectionProgressDialog> createState() => _ConnectionProgressDialogState();
}

class _ConnectionProgressDialogState extends State<ConnectionProgressDialog> {
  static const _steps = [
    'Ищу сервер…',
    'Соединяюсь с сервером…',
    'Аутентификация…',
    'Открываю SFTP-сессию…',
  ];

  int _current = 0;
  Timer? _timer;
  ConnectionOutcome _outcome = ConnectionOutcome.pending;
  /// Step that was active when the attempt failed.
  int _failedStep = -1;

  @override
  void initState() {
    super.initState();
    // Poll the real stage reported by the SSH layer instead of faking ticks.
    _timer = Timer.periodic(const Duration(milliseconds: 120), (timer) async {
      if (!mounted || _outcome != ConnectionOutcome.pending) return;
      try {
        final stage = await connectStage();
        if (!mounted || _outcome != ConnectionOutcome.pending) return;
        if (stage >= 1 && stage <= _steps.length) {
          setState(() => _current = (stage - 1).clamp(0, _steps.length - 1));
        }
      } catch (_) {
        // ignore polling errors
      }
    });
    widget.outcome.addListener(_onOutcome);
  }

  void _onOutcome() {
    if (!mounted) return;
    final next = widget.outcome.value;
    setState(() {
      _outcome = next;
      if (next == ConnectionOutcome.success) {
        _current = _steps.length - 1;
      } else if (next == ConnectionOutcome.failure) {
        // Never claim success: freeze on the step that actually failed.
        _failedStep = _current;
      }
    });
    if (next != ConnectionOutcome.pending) _timer?.cancel();
  }

  @override
  void dispose() {
    widget.outcome.removeListener(_onOutcome);
    _timer?.cancel();
    super.dispose();
  }

  _StepState _stateOf(int index) {
    if (_outcome == ConnectionOutcome.failure) {
      if (index < _failedStep) return _StepState.done;
      if (index == _failedStep) return _StepState.failed;
      return _StepState.pending;
    }
    if (_outcome == ConnectionOutcome.success) return _StepState.done;
    if (index < _current) return _StepState.done;
    if (index == _current) return _StepState.active;
    return _StepState.pending;
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.server.name.trim().isEmpty
        ? '${widget.server.user}@${widget.server.host}'
        : widget.server.name;

    return AlertDialog(
      insetPadding: const EdgeInsets.all(24),
      contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
      constraints: const BoxConstraints(maxWidth: 460),
      titlePadding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
      title: Row(
        children: [
          Icon(Icons.vpn_key_outlined, size: 18, color: T.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title, style: const TextStyle(fontSize: 14)),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _steps.length; i++)
            _StepRow(
              label: _steps[i],
              state: _stateOf(i),
            ),
          _StepRow(
            label: _outcome == ConnectionOutcome.failure
                ? 'Не удалось войти'
                : 'Соединение установлено',
            state: _outcome == ConnectionOutcome.failure
                ? _StepState.failed
                : (_outcome == ConnectionOutcome.success
                    ? _StepState.done
                    : _StepState.pending),
          ),
          const SizedBox(height: 6),
          Text(
            '${widget.server.user}@${widget.server.host}:${widget.server.port}',
            style: TextStyle(fontSize: 10.5, color: T.faint, fontFamily: T.monoFont),
          ),
        ],
      ),
      actions: [
        if (_outcome == ConnectionOutcome.pending && widget.onCancel != null)
          TextButton(
            onPressed: widget.onCancel,
            child: const Text('Отмена'),
          )
        else
          const SizedBox(height: 6),
      ],
    );
  }
}

enum _StepState { pending, active, done, failed }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      _StepState.done => T.success,
      _StepState.active => T.text,
      _StepState.failed => T.error,
      _StepState.pending => T.faint,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: switch (state) {
              _StepState.done => Icon(Icons.check, size: 14, color: T.success),
              _StepState.active => const Padding(
                  padding: EdgeInsets.all(3),
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
              _StepState.failed => Icon(Icons.close, size: 14, color: T.error),
              _StepState.pending => const Icon(Icons.circle_outlined, size: 9,
                  color: Color(0x336B7480)),
            },
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: color,
                fontWeight: state == _StepState.active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
