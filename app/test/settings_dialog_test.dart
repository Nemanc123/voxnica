import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voxnica/api/api_client.dart';
import 'package:voxnica/api/session_store.dart';
import 'package:voxnica/screens/settings_dialog.dart';
import 'package:voxnica/state/app_controller.dart';
import 'package:voxnica/theme.dart';

AppController buildController() => AppController(
  api: ApiClient(
    baseUrl: 'https://example.test/api/v1',
    store: SessionStore.memory(),
    client: MockClient(
      (request) async => http.Response(jsonEncode({'sessions': []}), 200),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('настройки открываются на разделе «Голос и видео»', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = buildController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SettingsDialog(
          controller: controller,
          fullScreen: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Голос и видео'), findsWidgets);
    expect(find.text('Шумоподавление'), findsOneWidget);
    expect(find.text('Автоусиление (AGC)'), findsOneWidget);
    expect(find.text('Камера'), findsOneWidget);
    expect(find.text('Включить превью'), findsOneWidget);

    await tester.tap(find.text('Аккаунт'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Выйти на всех устройствах'), findsOneWidget);
    expect(find.text('Смена пароля'), findsOneWidget);
    expect(find.text('Активные сессии'), findsOneWidget);
    expect(find.text('Активных сессий нет.'), findsOneWidget);
  });

  testWidgets('нельзя сменить пароль на тот же', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = buildController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SettingsDialog(controller: controller, fullScreen: true),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Аккаунт'));
    await tester.pump();
    await tester.pump();

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), 'same-password');
    await tester.enterText(fields.at(1), 'same-password');
    await tester.enterText(fields.at(2), 'same-password');

    await tester.ensureVisible(find.text('Сменить пароль'));
    await tester.pump();
    await tester.tap(find.text('Сменить пароль'));
    await tester.pump();

    expect(find.text('Новый пароль совпадает с текущим'), findsOneWidget);
  });

  testWidgets('настройки открываются в модальном окне', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = buildController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SettingsDialog(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Голос и видео'), findsWidgets);
    expect(find.text('О приложении'), findsOneWidget);
  });
}
