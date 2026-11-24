import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voxnica/screens/settings_dialog.dart';
import 'package:voxnica/state/app_controller.dart';
import 'package:voxnica/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('настройки открываются на разделе «Голос и видео»', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = AppController();
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
    expect(find.text('Выйти на всех устройствах'), findsOneWidget);
  });

  testWidgets('настройки открываются в модальном окне', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = AppController();
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
