import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Показывает код приглашения в сервер и позволяет скопировать его.
///
/// Вынесен отдельно от домашнего экрана, чтобы его можно было
/// проверить виджет-тестом без сети и контроллера.
class InviteCodeDialog extends StatelessWidget {
  const InviteCodeDialog({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Приглашение в сервер'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Передайте код человеку. В приложении он выбирает '
            '«Присоединиться по коду» и вводит его.',
            style: TextStyle(color: kTextMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: kRail,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              code,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Код скопирован')));
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Копировать'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Готово'),
        ),
      ],
    );
  }
}
