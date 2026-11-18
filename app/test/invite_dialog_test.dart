// Тест диалога приглашения: код виден и копируется.
// Сети нет — только виджет и подмена буфера обмена.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voxnica/theme.dart';
import 'package:voxnica/widgets/invite_dialog.dart';

void main() {
  testWidgets('диалог показывает код и копирует его', (tester) async {
    // Перехватываем системный канал буфера обмена: в тестах плагинов нет.
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments as Map<Object?, Object?>;
          copied.add(args['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(body: InviteCodeDialog(code: 'aB3dE9')),
      ),
    );

    expect(find.text('aB3dE9'), findsOneWidget);
    expect(find.text('Приглашение в сервер'), findsOneWidget);

    await tester.tap(find.text('Копировать'));
    await tester.pump();

    expect(copied, ['aB3dE9']);
    expect(find.text('Код скопирован'), findsOneWidget);
  });

  testWidgets('кнопка «Готово» закрывает диалог', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const InviteCodeDialog(code: 'x1y2z3'),
              ),
              child: const Text('открыть'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();
    expect(find.text('x1y2z3'), findsOneWidget);

    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    expect(find.text('x1y2z3'), findsNothing);
  });
}
