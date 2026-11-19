// Домашний раздел личных сообщений: структура как в Discord.
// Сети нет: контроллер не инициализируется, диалогов нет.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voxnica/screens/home_screen.dart';
import 'package:voxnica/state/app_controller.dart';
import 'package:voxnica/theme.dart';

void main() {
  testWidgets('домашний раздел ЛС показывает поиск, друзей и сообщения', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = AppController();
    addTearDown(controller.dispose);
    controller.openDmHome();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: HomeScreen(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.text('Найти или начать беседу'), findsOneWidget);
    expect(find.text('Друзья'), findsOneWidget);
    expect(find.text('ЛИЧНЫЕ СООБЩЕНИЯ'), findsOneWidget);
    expect(find.text('Нажмите «+», чтобы начать беседу'), findsOneWidget);
  });

  testWidgets('сервер показывает каналы, а не раздел ЛС', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = AppController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: HomeScreen(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.text('Найти или начать беседу'), findsNothing);
    expect(find.text('Серверы'), findsOneWidget);
  });
}
