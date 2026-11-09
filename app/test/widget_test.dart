// Дымовой тест UI: экран входа и переключение на регистрацию.
// Сети здесь нет — только виджеты.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voxnica/screens/auth_screen.dart';
import 'package:voxnica/state/app_controller.dart';
import 'package:voxnica/theme.dart';

void main() {
  testWidgets('экран входа переключается на регистрацию', (tester) async {
    final controller = AppController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: AuthScreen(controller: controller),
      ),
    );

    expect(find.text('С возвращением'), findsOneWidget);
    expect(find.byKey(const Key('auth_display_name')), findsNothing);

    await tester.tap(find.byKey(const Key('auth_toggle')));
    await tester.pumpAndSettle();

    expect(find.text('Создать аккаунт'), findsOneWidget);
    expect(find.byKey(const Key('auth_display_name')), findsOneWidget);
  });
}
