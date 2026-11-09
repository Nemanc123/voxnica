import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:voxnica/api/api_client.dart';
import 'package:voxnica/api/models.dart';
import 'package:voxnica/api/session_store.dart';

Map<String, dynamic> authJson(String access, String refresh) => {
      'user': {'id': 'u1', 'username': 'alice'},
      'access_token': access,
      'refresh_token': refresh,
      'expires_in': 900,
    };

void main() {
  test('после 401 клиент обновляет токен и повторяет запрос', () async {
    var guildCalls = 0;
    var refreshCalls = 0;

    final client = MockClient((request) async {
      final path = request.url.path;

      if (path.endsWith('/auth/login')) {
        return http.Response(
          jsonEncode(authJson('old-access', 'refresh-1')),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (path.endsWith('/auth/refresh')) {
        refreshCalls++;
        return http.Response(
          jsonEncode(authJson('new-access', 'refresh-2')),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (path.endsWith('/guilds')) {
        guildCalls++;
        if (request.headers['Authorization'] == 'Bearer new-access') {
          return http.Response(
            jsonEncode({
              'guilds': [
                {'id': 'g1', 'name': 'Тестовый сервер'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'error': {'code': 'invalid_token', 'message': 'истёк'},
          }),
          401,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response('{}', 404);
    });

    final api = ApiClient(
      baseUrl: 'http://example.test/api/v1',
      client: client,
      store: SessionStore.memory(),
    );

    await api.login('alice', 'very-long-password');
    final guilds = await api.listGuilds();

    expect(guildCalls, 2, reason: 'первый запрос 401, второй — после refresh');
    expect(refreshCalls, 1);
    expect(guilds.single.name, 'Тестовый сервер');
  });

  test('presign, загрузка в S3 и сообщение с вложением', () async {
    var uploaded = false;
    var messageBody = <String, dynamic>{};

    final client = MockClient((request) async {
      final path = request.url.path;

      if (path.endsWith('/attachments/presign')) {
        return http.Response(
          jsonEncode({
            'storage_key': 'attachments/c1/a.txt',
            'upload_url': 'http://storage.test/voxnica/a.txt',
            'expires_in': 900,
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.host == 'storage.test') {
        uploaded = true;
        expect(request.method, 'PUT');
        return http.Response('', 200);
      }

      if (path.endsWith('/messages')) {
        messageBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 'm1',
            'seq': 1,
            'channel_id': 'c1',
            'author_id': 'u1',
            'content': '',
            'created_at': '2026-11-09T12:00:00Z',
            'attachments': [
              {
                'id': 'a1',
                'filename': 'a.txt',
                'content_type': 'text/plain',
                'size_bytes': 5,
                'storage_key': 'attachments/c1/a.txt',
              },
            ],
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response('{}', 404);
    });

    final api = ApiClient(
      baseUrl: 'http://example.test/api/v1',
      client: client,
      store: SessionStore.memory(),
    );

    final presign = await api.presignAttachment(
      channelId: 'c1',
      filename: 'a.txt',
      contentType: 'text/plain',
      sizeBytes: 5,
    );
    expect(presign.storageKey, 'attachments/c1/a.txt');

    await api.uploadAttachment(
      presign,
      [104, 101, 108, 108, 111],
      contentType: 'text/plain',
    );
    expect(uploaded, isTrue);

    final message = await api.sendMessageWithAttachments(
      'c1',
      '',
      [
        PendingAttachment(
          storageKey: presign.storageKey,
          filename: 'a.txt',
          contentType: 'text/plain',
          sizeBytes: 5,
        ),
      ],
    );

    expect(message.attachments.single.filename, 'a.txt');
    expect(
      (messageBody['attachments'] as List<dynamic>).length,
      1,
    );
  });

  test('ошибка API разбирается в код и сообщение', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'error': {
            'code': 'validation_error',
            'message': 'пароль короче 10 символов',
          },
        }),
        400,
        headers: {'content-type': 'application/json'},
      );
    });

    final api = ApiClient(
      baseUrl: 'http://example.test/api/v1',
      client: client,
      store: SessionStore.memory(),
    );

    expect(
      () => api.login('alice', 'short'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'validation_error')
            .having((e) => e.status, 'status', 400),
      ),
    );
  });
}
