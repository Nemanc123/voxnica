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
}
