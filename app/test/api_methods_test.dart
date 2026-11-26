// Проверка, что HTTP-клиент умеет все методы, которые использует.
//
// Регрессия, из-за которой появился файл: в `_request` не было обработки
// PUT, поэтому блокировка друзей падала с ArgumentError ещё до сети, и в
// логах API не появлялось ни одного запроса.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:voxnica/api/api_client.dart';
import 'package:voxnica/api/models.dart';
import 'package:voxnica/api/session_store.dart';

Future<ApiClient> buildClient({
  required Future<http.Response> Function(http.Request) handler,
  Duration requestTimeout = const Duration(seconds: 15),
}) async {
  final store = SessionStore.memory();
  await store.save(
    const AuthSession(
      user: User(id: 'me', username: 'me'),
      accessToken: 'token',
      refreshToken: 'refresh',
    ),
  );

  final client = ApiClient(
    baseUrl: 'https://example.test/api/v1',
    client: MockClient(handler),
    store: store,
    requestTimeout: requestTimeout,
  );
  await client.restore();
  return client;
}

void main() {
  test('блокировка отправляется методом PUT с телом blocked=true', () async {
    http.Request? captured;

    final api = await buildClient(
      handler: (request) async {
        captured = request;
        return http.Response('', 204);
      },
    );

    await api.setBlocked('user-1', true);

    expect(captured, isNotNull);
    expect(captured!.method, 'PUT');
    expect(captured!.url.path, '/api/v1/relationships/user-1/block');
    expect(captured!.body, '{"blocked":true}');
    expect(captured!.headers['Authorization'], 'Bearer token');
  });

  test('выход на всех устройствах идёт на /auth/logout-all', () async {
    http.Request? captured;

    final api = await buildClient(
      handler: (request) async {
        captured = request;
        return http.Response('', 204);
      },
    );

    await api.logoutAll();

    expect(captured, isNotNull);
    expect(captured!.method, 'POST');
    expect(captured!.url.path, '/api/v1/auth/logout-all');
    expect(captured!.headers['Authorization'], 'Bearer token');
    expect(api.isAuthenticated, isFalse);
  });

  test('запрос не висит вечно при молчащем сервере', () async {
    final api = await buildClient(
      requestTimeout: const Duration(milliseconds: 50),
      handler: (_) => Completer<http.Response>().future,
    );

    await expectLater(
      api.listGuilds(),
      throwsA(
        isA<ApiException>().having((error) => error.code, 'code', 'timeout'),
      ),
    );
  });

  test('смена пароля очищает локальную сессию', () async {
    http.Request? captured;

    final api = await buildClient(
      handler: (request) async {
        captured = request;
        return http.Response('', 204);
      },
    );

    await api.changePassword(
      currentPassword: 'old-password-1',
      newPassword: 'new-password-2',
    );

    expect(captured, isNotNull);
    expect(captured!.method, 'POST');
    expect(captured!.url.path, '/api/v1/auth/password');
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body['current_password'], 'old-password-1');
    expect(body['new_password'], 'new-password-2');
    expect(api.isAuthenticated, isFalse);
  });

  test('сессии читаются и завершаются', () async {
    final calls = <http.Request>[];

    final api = await buildClient(
      handler: (request) async {
        calls.add(request);
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'sessions': [
                {
                  'id': 's-1',
                  'user_agent': 'Dart/3.0 (dart:io)',
                  'ip': '10.0.0.1',
                  'created_at': '2026-11-23T10:00:00Z',
                  'last_seen_at': '2026-11-23T11:00:00Z',
                  'current': true,
                },
              ],
            }),
            200,
          );
        }
        return http.Response('', 204);
      },
    );

    final sessions = await api.sessions();
    expect(sessions, hasLength(1));
    expect(sessions.first.id, 's-1');
    expect(sessions.first.ip, '10.0.0.1');
    expect(sessions.first.current, isTrue);
    expect(sessions.first.createdAt, isNotNull);

    await api.revokeSession('s-2');
    expect(calls.last.method, 'DELETE');
    expect(calls.last.url.path, '/api/v1/auth/sessions/s-2');
  });

  test('снятие блокировки отправляется с blocked=false', () async {
    http.Request? captured;

    final api = await buildClient(
      handler: (request) async {
        captured = request;
        return http.Response('', 204);
      },
    );

    await api.setBlocked('user-1', false);

    expect(captured!.method, 'PUT');
    expect(captured!.body, '{"blocked":false}');
  });

  test('групповые методы ходят нужными путями и телами', () async {
    final requests = <http.Request>[];

    final api = await buildClient(
      handler: (request) async {
        requests.add(request);
        final path = request.url.path;

        if (path == '/api/v1/dms/group') {
          return http.Response(
            '{"id":"g1","type":"group_dm","recipients":[]}',
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/v1/dms/g1' && request.method == 'PATCH') {
          return http.Response(
            '{"id":"g1","type":"group_dm","name":"Новое","recipients":[]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/v1/dms/g1/recipients' &&
            request.method == 'POST') {
          return http.Response(
            '{"id":"g1","type":"group_dm","recipients":[]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path == '/api/v1/dms/g1/recipients/u3' &&
            request.method == 'DELETE') {
          return http.Response('', 204);
        }
        throw StateError('неожиданный запрос: ${request.method} $path');
      },
    );

    await api.createDmGroup(['u1', 'u2'], name: 'Проект');
    await api.renameDm('g1', 'Новое');
    await api.addDmRecipient('g1', 'u3');
    await api.removeDmRecipient('g1', 'u3');

    expect(requests[0].method, 'POST');
    expect(requests[0].url.path, '/api/v1/dms/group');
    expect(requests[0].body, '{"recipient_ids":["u1","u2"],"name":"Проект"}');

    expect(requests[1].method, 'PATCH');
    expect(requests[1].url.path, '/api/v1/dms/g1');
    expect(requests[1].body, '{"name":"Новое"}');

    expect(requests[2].method, 'POST');
    expect(requests[2].url.path, '/api/v1/dms/g1/recipients');
    expect(requests[2].body, '{"user_id":"u3"}');

    expect(requests[3].method, 'DELETE');
    expect(requests[3].url.path, '/api/v1/dms/g1/recipients/u3');
  });
}
