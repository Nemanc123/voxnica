// Проверка, что HTTP-клиент умеет все методы, которые использует.
//
// Регрессия, из-за которой появился файл: в `_request` не было обработки
// PUT, поэтому блокировка друзей падала с ArgumentError ещё до сети, и в
// логах API не появлялось ни одного запроса.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:voxnica/api/api_client.dart';
import 'package:voxnica/api/models.dart';
import 'package:voxnica/api/session_store.dart';

Future<ApiClient> buildClient({
  required Future<http.Response> Function(http.Request) handler,
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
