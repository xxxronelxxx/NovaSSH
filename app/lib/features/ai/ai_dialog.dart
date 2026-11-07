import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../design/ui.dart';
import 'ai_client.dart';

/// What the user chose in the assistant dialog.
class AiAnswer {
  const AiAnswer({
    required this.command,
    this.run = false,
    this.saveAsSnippet = false,
  });

  final String command;

  /// Run the command right away (the caller asks for confirmation).
  final bool run;

  /// Open the snippet editor with this command.
  final bool saveAsSnippet;
}

/// Asks the model for one shell command and returns the chosen action.
///
/// The dialog never types into the terminal itself: the caller decides whether
/// to insert or run the command.
Future<AiAnswer?> showAiAsk(
  BuildContext context, {
  required String questionHint,
  String contextText = '',
  String initialQuestion = '',
  String? serverTitle,
}) {
  return showDialog<AiAnswer>(
    context: context,
    builder: (ctx) => _AiDialog(
      questionHint: questionHint,
      contextText: contextText,
      initialQuestion: initialQuestion,
      serverTitle: serverTitle,
    ),
  );
}

class _AiDialog extends StatefulWidget {
  const _AiDialog({
    required this.questionHint,
    required this.contextText,
    required this.initialQuestion,
    this.serverTitle,
  });

  final String questionHint;
  final String contextText;
  final String initialQuestion;
  final String? serverTitle;

  @override
  State<_AiDialog> createState() => _AiDialogState();
}

class _AiDialogState extends State<_AiDialog> {
  late final TextEditingController _question;
  AiClient? _client;
  bool _loadingClient = true;
  bool _busy = false;
  String? _error;
  String? _command;
  String? _meta;

  @override
  void initState() {
    super.initState();
    _question = TextEditingController(text: widget.initialQuestion);
    _loadClient();
  }

  Future<void> _loadClient() async {
    try {
      final client = await configuredAiClient();
      if (!mounted) return;
      setState(() {
        _client = client;
        _loadingClient = false;
      });
      if (client == null) return;
      if (_question.text.isNotEmpty) {
        await Future<void>.delayed(Duration.zero);
        if (mounted) await _ask();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingClient = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final client = _client;
    final question = _question.text.trim();
    if (client == null || _busy) return;
    if (question.isEmpty) {
      setState(() => _error = 'Напишите, что нужно сделать на сервере');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _command = null;
      _meta = null;
    });
    try {
      final command = await client.askCommand(
        question: question,
        context: widget.contextText,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _command = command;
        _meta = client.model;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final command = _command;
    final multiline = command != null && command.contains('\n');
    return DialogShortcuts(
      onConfirm: () {
        if (_busy) return;
        if (_command == null) {
          _ask();
        } else {
          Navigator.pop(context, AiAnswer(command: _command!));
        }
      },
      onCancel: () => Navigator.pop(context),
      child: AlertDialog(
        backgroundColor: T.menu,
        insetPadding: const EdgeInsets.all(16),
        title: Row(
          children: [
            Icon(Icons.auto_awesome, size: 16, color: T.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.serverTitle == null
                    ? 'Помощник ИИ'
                    : 'Помощник ИИ · ${widget.serverTitle}',
                style: const TextStyle(fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_loadingClient)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_client == null)
                  Text(
                    'ИИ не настроен. Откройте Настройки → ИИ: выберите '
                    'провайдера, вставьте API-ключ и модель.\n\n'
                    'Помощник только предлагает команду — сам он ничего не '
                    'выполняет.',
                    style: TextStyle(fontSize: 12.5, color: T.dim, height: 1.5),
                  )
                else ...[
                  TextField(
                    controller: _question,
                    autofocus: true,
                    minLines: 2,
                    maxLines: 4,
                    style: const TextStyle(fontSize: 12.5),
                    decoration: InputDecoration(
                      labelText: 'Что сделать на сервере?',
                      hintText: widget.questionHint,
                    ),
                    onSubmitted: (_) => _ask(),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: PrimaryButton(
                      label: _busy ? 'Думаю…' : 'Спросить',
                      icon: Icons.send,
                      onPressed: _busy ? null : _ask,
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: T.error.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(T.radiusSmall),
                        border: Border.all(
                          color: T.error.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          fontSize: 12,
                          color: T.error,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                  if (command != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xF21A1D23),
                        borderRadius: BorderRadius.circular(T.radiusSmall),
                        border: Border.all(color: T.border),
                      ),
                      child: SelectableText(
                        command,
                        style: TextStyle(
                          fontFamily: T.monoFont,
                          fontSize: 13.5,
                          height: 1.45,
                          // The code block is dark in both themes, so the text
                          // must not follow the (light-theme) T.text colour.
                          color: Color(0xFFE8ECF3),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      multiline
                          ? 'Команда из нескольких строк — проверьте её перед '
                                'выполнением'
                          : 'Сам ИИ ничего не выполняет — выберите действие',
                      style: TextStyle(
                        fontSize: 11,
                        color: multiline ? T.error : T.dim,
                        height: 1.4,
                      ),
                    ),
                    if (_meta != null)
                      Text(
                        _meta!,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: T.dim,
                          fontFamily: T.monoFont,
                        ),
                      ),
                  ],
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
          if (command != null) ...[
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                AiAnswer(command: command, saveAsSnippet: true),
              ),
              child: const Text('Сохранить как сниппет'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, AiAnswer(command: command, run: true)),
              child: const Text('Выполнить'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, AiAnswer(command: command)),
              child: const Text('Вставить'),
            ),
          ],
        ],
      ),
    );
  }
}
