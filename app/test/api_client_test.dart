import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:voxnica/api/api_client.dart';

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
    );

    await api.login('alice', 'very-long-password');
    final guilds = await api.listGuilds();

    expect(guildCalls, 2, reason: 'первый запрос 401, второй — после refresh');
    expect(refreshCalls, 1);
    expect(guilds.single.name, 'Тестовый сервер');
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
