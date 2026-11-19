// Почему этот файл существует.
//
// 19.11.2026 пользователь нажал «Разблокировать» и решил, что кнопка
// не работает: запрос уходил и блокировка снималась, но выдача поиска
// не перезапрашивалась, поэтому рядом с человеком оставалась та же
// кнопка «Разблокировать». Тест закрепляет: после действия поиск
// обновляется, и отношение в строке меняется на актуальное.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:voxnica/api/api_client.dart';
import 'package:voxnica/api/models.dart';
import 'package:voxnica/api/session_store.dart';
import 'package:voxnica/state/friends_controller.dart';

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

http.Response json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('после разблокировки поиск перезапрашивается и связь обновляется',
      () async {
    var searches = 0;

    final api = await buildClient(
      handler: (request) async {
        final path = request.url.path;

        if (request.method == 'GET' && path == '/api/v1/users/search') {
          searches++;
          // Первый запрос — человек заблокирован, второй — уже нет.
          return json({
            'users': [
              {
                'id': 'u2',
                'username': 'bob',
                'display_name': 'Bob',
                'relation': searches == 1 ? 'blocked' : 'none',
              },
            ],
          });
        }

        if (request.method == 'GET' && path == '/api/v1/relationships') {
          return json({
            'friends': <Object>[],
            'incoming': <Object>[],
            'outgoing': <Object>[],
            'blocked': <Object>[],
          });
        }

        if (request.method == 'PUT' &&
            path == '/api/v1/relationships/u2/block') {
          expect(request.body, '{"blocked":false}');
          return http.Response('', 204);
        }

        throw StateError('неожиданный запрос: ${request.method} $path');
      },
    );

    final friends = FriendsController(api);
    await friends.search('bob');

    expect(friends.results.single.relation, 'blocked');
    expect(searches, 1);

    final ok = await friends.setBlocked('u2', false);

    expect(ok, isTrue);
    expect(searches, 2, reason: 'выдача поиска должна обновиться');
    expect(friends.results.single.relation, 'none');
  });

  test('reset очищает поиск и списки после смены аккаунта', () async {
    final api = await buildClient(
      handler: (request) async {
        final path = request.url.path;

        if (request.method == 'GET' && path == '/api/v1/relationships') {
          return json({
            'friends': <Object>[],
            'incoming': <Object>[],
            'outgoing': <Object>[],
            'blocked': [
              {
                'user': {'id': 'u2', 'username': 'bob'},
                'since': null,
              },
            ],
          });
        }

        if (request.method == 'GET' &&
            path == '/api/v1/relationships/presence') {
          return json({
            'presence': {'u2': 'online'},
          });
        }

        if (request.method == 'GET' && path == '/api/v1/users/search') {
          return json({
            'users': [
              {'id': 'u2', 'username': 'bob', 'relation': 'blocked'},
            ],
          });
        }

        throw StateError('неожиданный запрос: ${request.method} $path');
      },
    );

    final friends = FriendsController(api);
    await friends.load();
    await friends.search('bob');

    expect(friends.results, isNotEmpty);
    expect(friends.view.blocked, isNotEmpty);
    expect(friends.presence, isNotEmpty);

    friends.reset();

    expect(friends.results, isEmpty);
    expect(friends.view.blocked, isEmpty);
    expect(friends.view.friends, isEmpty);
    expect(friends.presence, isEmpty);
    expect(friends.error, isNull);
  });
}
