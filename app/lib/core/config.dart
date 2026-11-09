import 'package:flutter/foundation.dart';

/// Адрес API.
///
/// Переопределяется при сборке:
///   flutter run --dart-define=API_URL=http://192.168.1.10:8080/api/v1
///
/// По умолчанию: Android-эмулятор видит хост как 10.0.2.2,
/// остальные платформы — как 127.0.0.1.
const String _override = String.fromEnvironment('API_URL');

String get apiBaseUrl {
  if (_override.isNotEmpty) return _override;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:8080/api/v1';
  }
  return 'http://127.0.0.1:8080/api/v1';
}

String get gatewayUrl {
  final uri = Uri.parse(apiBaseUrl);
  final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
  final path = uri.path.replaceFirst(RegExp(r'/api/v1/?$'), '');
  return uri.replace(scheme: scheme, path: '$path/gateway').toString();
}
