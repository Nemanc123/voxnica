import 'package:shared_preferences/shared_preferences.dart';

/// Пользовательские настройки, которые переживают перезапуск приложения.
///
/// Здесь только несекретные параметры: устройства, обработка звука, громкость.
/// Токены и пароли остаются в `SessionStore`.
class AppSettings {
  static const _micKey = 'settings.mic_device_id';
  static const _outputKey = 'settings.output_device_id';
  static const _noiseKey = 'settings.noise_suppression';
  static const _agcKey = 'settings.auto_gain_control';
  static const _echoKey = 'settings.echo_cancellation';
  static const _volumeKey = 'settings.output_volume';
  static const _cameraKey = 'settings.camera_device_id';
  static const _cameraResolutionKey = 'settings.camera_resolution';
  static const _cameraFpsKey = 'settings.camera_fps';
  static const _mirrorKey = 'settings.camera_mirror_preview';

  String? micDeviceId;
  String? outputDeviceId;
  bool noiseSuppression = true;
  bool autoGainControl = true;
  bool echoCancellation = true;
  double outputVolume = 1.0;
  String? cameraDeviceId;
  String cameraResolution = '720p';
  int cameraFps = 30;
  bool mirrorPreview = true;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    micDeviceId = prefs.getString(_micKey);
    outputDeviceId = prefs.getString(_outputKey);
    noiseSuppression = prefs.getBool(_noiseKey) ?? true;
    autoGainControl = prefs.getBool(_agcKey) ?? true;
    echoCancellation = prefs.getBool(_echoKey) ?? true;
    outputVolume = (prefs.getDouble(_volumeKey) ?? 1.0)
        .clamp(0.0, 1.0)
        .toDouble();
    cameraDeviceId = prefs.getString(_cameraKey);
    cameraResolution = prefs.getString(_cameraResolutionKey) == '1080p'
        ? '1080p'
        : '720p';
    cameraFps = prefs.getInt(_cameraFpsKey) == 15 ? 15 : 30;
    mirrorPreview = prefs.getBool(_mirrorKey) ?? true;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await _writeString(prefs, _micKey, micDeviceId);
    await _writeString(prefs, _outputKey, outputDeviceId);
    await prefs.setBool(_noiseKey, noiseSuppression);
    await prefs.setBool(_agcKey, autoGainControl);
    await prefs.setBool(_echoKey, echoCancellation);
    await prefs.setDouble(_volumeKey, outputVolume.clamp(0.0, 1.0).toDouble());
    await _writeString(prefs, _cameraKey, cameraDeviceId);
    await prefs.setString(
      _cameraResolutionKey,
      cameraResolution == '1080p' ? '1080p' : '720p',
    );
    await prefs.setInt(_cameraFpsKey, cameraFps == 15 ? 15 : 30);
    await prefs.setBool(_mirrorKey, mirrorPreview);
  }

  Future<void> _writeString(
    SharedPreferences prefs,
    String key,
    String? value,
  ) async {
    if (value == null || value.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }
}
