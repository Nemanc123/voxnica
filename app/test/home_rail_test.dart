// Проверка, что кнопки приглашений действительно есть в дереве виджетов.
// Сети нет: контроллер не инициализируется, серверов нет.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voxnica/screens/home_screen.dart';
import 'package:voxnica/state/app_controller.dart';
import 'package:voxnica/theme.dart';

void main() {
  testWidgets('на домашнем экране есть кнопка «Присоединиться по коду»', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: HomeScreen(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Присоединиться по коду'), findsOneWidget);
    expect(find.byTooltip('Создать сервер'), findsOneWidget);
  });
}
