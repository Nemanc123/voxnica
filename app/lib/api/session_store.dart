import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';

/// Хранилище сессии.
///
/// Основной режим — `flutter_secure_storage`: на Windows это DPAPI,
/// на Android — Keystore, на iOS — Keychain. Пароль в открытом виде
/// на диск не попадает.
///
/// `SessionStore.memory()` нужен тестам: в `flutter test` плагинов нет.
class SessionStore {
  SessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  SessionStore.memory() : _storage = null;

  static const _key = 'auth_session';

  final FlutterSecureStorage? _storage;
  AuthSession? _cached;

  Future<AuthSession?> load() async {
    if (_cached != null) return _cached;

    final storage = _storage;
    if (storage == null) return null;

    try {
      final raw = await storage.read(key: _key);
      if (raw == null || raw.isEmpty) return null;

      final json = jsonDecode(raw) as Map<String, dynamic>;
      final session = AuthSession.fromStorageJson(json);
      _cached = session;
      return session;
    } catch (_) {
      // Повреждённая запись не должна ронять приложение — просто вход заново.
      await storage.delete(key: _key);
      return null;
    }
  }

  Future<void> save(AuthSession session) async {
    _cached = session;

    final storage = _storage;
    if (storage == null) return;

    await storage.write(
      key: _key,
      value: jsonEncode(session.toStorageJson()),
    );
  }

  Future<void> clear() async {
    _cached = null;

    final storage = _storage;
    if (storage == null) return;

    await storage.delete(key: _key);
  }
}
