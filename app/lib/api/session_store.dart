import '../api/models.dart';

/// Хранилище сессии.
///
/// Пока в памяти: после перезапуска приложения нужно войти заново.
/// Постоянное хранение требует плагина (flutter_secure_storage), а он
/// на этой машине блокируется выключенным Developer Mode. Это осознанное
/// временное ограничение, записано в docs/02-media-and-client.md.
class SessionStore {
  AuthSession? _session;

  AuthSession? get current => _session;

  Future<AuthSession?> load() async => _session;

  Future<void> save(AuthSession session) async {
    _session = session;
  }

  Future<void> clear() async {
    _session = null;
  }
}
