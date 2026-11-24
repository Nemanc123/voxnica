import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voxnica/state/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('настройки по умолчанию', () async {
    final settings = AppSettings();
    await settings.load();

    expect(settings.noiseSuppression, isTrue);
    expect(settings.autoGainControl, isTrue);
    expect(settings.echoCancellation, isTrue);
    expect(settings.outputVolume, 1.0);
    expect(settings.micDeviceId, isNull);
    expect(settings.outputDeviceId, isNull);
  });

  test('настройки сохраняются и загружаются', () async {
    final settings = AppSettings()
      ..micDeviceId = 'mic-1'
      ..outputDeviceId = 'out-1'
      ..noiseSuppression = false
      ..autoGainControl = false
      ..echoCancellation = false
      ..outputVolume = 0.4;
    await settings.save();

    final loaded = AppSettings();
    await loaded.load();

    expect(loaded.micDeviceId, 'mic-1');
    expect(loaded.outputDeviceId, 'out-1');
    expect(loaded.noiseSuppression, isFalse);
    expect(loaded.autoGainControl, isFalse);
    expect(loaded.echoCancellation, isFalse);
    expect(loaded.outputVolume, 0.4);
  });
}
