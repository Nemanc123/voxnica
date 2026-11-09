import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import 'models.dart';
import 'session_store.dart';

/// Ошибка API с машинным кодом и человекочитаемым текстом.
class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  bool get isUnauthorized => status == 401;

  @override
  String toString() => message;
}

/// HTTP-клиент.
///
/// Умеет одно важное: если access-токен истёк, один раз обновить его
/// через refresh и повторить запрос. Параллельные запросы ждут один refresh,
/// а не запускают пять.
class ApiClient {
  ApiClient({
    String? baseUrl,
    http.Client? client,
    SessionStore? store,
  })  : baseUrl = (baseUrl ?? apiBaseUrl).replaceFirst(RegExp(r'/$'), ''),
        _http = client ?? http.Client(),
        _store = store ?? SessionStore();

  final String baseUrl;
  final http.Client _http;
  final SessionStore _store;

  AuthSession? _session;
  Future<bool>? _refreshing;

  User? get user => _session?.user;
  bool get isAuthenticated => _session != null;

  Future<void> restore() async {
    _session = await _store.load();
  }

  /// Токен для WebSocket. Обновляет access, если он скоро истечёт:
  /// шлюз живёт дольше токена, и при переподключении нужен свежий.
  Future<String> freshAccessToken() async {
    final session = _session;
    if (session == null) {
      throw const ApiException(401, 'unauthorized', 'Нужно войти заново');
    }

    final expiresAt = session.expiresAt;
    final soon = expiresAt != null &&
        DateTime.now().isAfter(expiresAt.subtract(const Duration(seconds: 30)));

    if (soon && await _refresh()) {
      return _session!.accessToken;
    }

    return session.accessToken;
  }

  Future<AuthSession> login(String login, String password) async {
    final json = await _request(
      'POST',
      '/auth/login',
      body: {'login': login, 'password': password},
      auth: false,
    );
    final session = AuthSession.fromJson(json!);
    await _setSession(session);
    return session;
  }

  Future<AuthSession> register({
    required String username,
    required String password,
    String? displayName,
  }) async {
    final body = <String, dynamic>{
      'username': username,
      'password': password,
    };
    if (displayName != null && displayName.trim().isNotEmpty) {
      body['display_name'] = displayName.trim();
    }

    final json = await _request(
      'POST',
      '/auth/register',
      body: body,
      auth: false,
    );
    final session = AuthSession.fromJson(json!);
    await _setSession(session);
    return session;
  }

  Future<void> logout() async {
    try {
      await _request('POST', '/auth/logout');
    } catch (_) {
      // Сеть могла умереть — локальную сессию всё равно очищаем.
    }
    await _clearSession();
  }

  Future<List<Guild>> listGuilds() async {
    final json = await _request('GET', '/guilds');
    final raw = json?['guilds'] as List<dynamic>? ?? [];
    return raw.cast<Map<String, dynamic>>().map(Guild.fromJson).toList();
  }

  Future<GuildDetail> createGuild(String name) async {
    final json = await _request('POST', '/guilds', body: {'name': name});
    return GuildDetail.fromJson(json!);
  }

  Future<GuildDetail> guildDetail(String guildId) async {
    final json = await _request('GET', '/guilds/$guildId');
    return GuildDetail.fromJson(json!);
  }

  Future<Channel> createChannel({
    required String guildId,
    required String name,
    required String type,
  }) async {
    final json = await _request(
      'POST',
      '/guilds/$guildId/channels',
      body: {'name': name, 'type': type},
    );
    return Channel.fromJson(json!);
  }

  Future<List<GuildMember>> members(String guildId) async {
    final json = await _request('GET', '/guilds/$guildId/members');
    final raw = json?['members'] as List<dynamic>? ?? [];
    return raw
        .cast<Map<String, dynamic>>()
        .map(GuildMember.fromJson)
        .toList();
  }

  Future<List<Message>> messages(
    String channelId, {
    int before = 0,
    int limit = 50,
  }) async {
    final json = await _request(
      'GET',
      '/channels/$channelId/messages',
      query: {'before': '$before', 'limit': '$limit'},
    );
    final raw = json?['messages'] as List<dynamic>? ?? [];
    return raw.cast<Map<String, dynamic>>().map(Message.fromJson).toList();
  }

  Future<Message> sendMessage(String channelId, String content) =>
      sendMessageWithAttachments(channelId, content, const []);

  Future<Message> sendMessageWithAttachments(
    String channelId,
    String content,
    List<PendingAttachment> attachments,
  ) async {
    final json = await _request(
      'POST',
      '/channels/$channelId/messages',
      body: {
        'content': content,
        'attachments': attachments.map((a) => a.toJson()).toList(),
      },
    );
    return Message.fromJson(json!);
  }

  Future<PresignResult> presignAttachment({
    required String channelId,
    required String filename,
    required String contentType,
    required int sizeBytes,
  }) async {
    final json = await _request(
      'POST',
      '/channels/$channelId/attachments/presign',
      body: {
        'filename': filename,
        'content_type': contentType,
        'size_bytes': sizeBytes,
      },
    );
    return PresignResult.fromJson(json!);
  }

  /// Загрузка идёт напрямую в S3 по подписанной ссылке, минуя Go-сервер.
  Future<void> uploadAttachment(
    PresignResult presign,
    List<int> bytes, {
    required String contentType,
  }) async {
    final response = await _http.put(
      Uri.parse(presign.uploadUrl),
      headers: {'Content-Type': contentType},
      body: bytes,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.statusCode,
        'upload_failed',
        'Хранилище не приняло файл (код ${response.statusCode})',
      );
    }
  }

  Future<void> markRead(String channelId, int seq) async {
    await _request(
      'POST',
      '/channels/$channelId/read',
      body: {'seq': seq},
    );
  }

  Future<VoiceJoinInfo> voiceJoin(String channelId) async {
    final json = await _request(
      'POST',
      '/channels/$channelId/voice/join',
      body: <String, dynamic>{},
    );
    return VoiceJoinInfo.fromJson(json!);
  }

  Future<List<VoiceParticipant>> voiceParticipants(String channelId) async {
    final json = await _request('GET', '/channels/$channelId/voice');
    final raw = json?['participants'] as List<dynamic>? ?? [];
    return raw
        .cast<Map<String, dynamic>>()
        .map(VoiceParticipant.fromJson)
        .toList();
  }

  Future<void> voiceState(
    String channelId, {
    required bool selfMute,
    required bool selfDeaf,
  }) async {
    await _request(
      'PATCH',
      '/channels/$channelId/voice/state',
      body: {'self_mute': selfMute, 'self_deaf': selfDeaf},
    );
  }

  /// Прямая ссылка на скачивание. Требует заголовок Authorization,
  /// поэтому открывать её в браузере без токена нельзя.
  String attachmentUrl(String attachmentId) =>
      '$baseUrl/attachments/$attachmentId/download';

  Future<Map<String, dynamic>?> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool auth = true,
    bool retry = true,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final headers = <String, String>{'Content-Type': 'application/json'};

    if (auth) {
      final token = _session?.accessToken;
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }

    late http.Response response;
    final payload = body == null ? null : jsonEncode(body);

    switch (method) {
      case 'GET':
        response = await _http.get(uri, headers: headers);
      case 'POST':
        response = await _http.post(uri, headers: headers, body: payload);
      case 'PATCH':
        response = await _http.patch(uri, headers: headers, body: payload);
      case 'DELETE':
        response = await _http.delete(uri, headers: headers);
      default:
        throw ArgumentError('Неизвестный метод $method');
    }

    if (response.statusCode == 401 &&
        auth &&
        retry &&
        _session?.refreshToken != null) {
      if (await _refresh()) {
        return _request(
          method,
          path,
          body: body,
          query: query,
          auth: auth,
          retry: false,
        );
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.bodyBytes.isEmpty) return null;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    }

    throw _parseError(response);
  }

  Future<bool> _refresh() {
    final running = _refreshing;
    if (running != null) return running;

    final future = _doRefresh();
    _refreshing = future;
    future.whenComplete(() => _refreshing = null);
    return future;
  }

  Future<bool> _doRefresh() async {
    final refreshToken = _session?.refreshToken;
    if (refreshToken == null) return false;

    try {
      final json = await _request(
        'POST',
        '/auth/refresh',
        body: {'refresh_token': refreshToken},
        auth: false,
        retry: false,
      );
      if (json == null) return false;

      final session = AuthSession.fromJson(json);
      await _setSession(session);
      return true;
    } catch (_) {
      await _clearSession();
      return false;
    }
  }

  Future<void> _setSession(AuthSession session) async {
    _session = session;
    await _store.save(session);
  }

  Future<void> _clearSession() async {
    _session = null;
    await _store.clear();
  }

  ApiException _parseError(http.Response response) {
    var code = 'http_${response.statusCode}';
    var message = 'Ошибка ${response.statusCode}';

    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final error = decoded is Map<String, dynamic> ? decoded['error'] : null;
      if (error is Map<String, dynamic>) {
        code = error['code'] as String? ?? code;
        message = error['message'] as String? ?? message;
      }
    } catch (_) {
      // Тело не JSON — оставляем общий текст.
    }

    return ApiException(response.statusCode, code, message);
  }
}
