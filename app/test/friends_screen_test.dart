// Экран друзей: заблокированные видны и разблокируются.
//
// Причина появления файла (P-45, 1.0.7): кнопка «Разблокировать» была только
// в выдаче поиска, а после нажатия выдача не перезапрашивалась — со стороны
// это выглядело как мёртвая кнопка. Здесь проверяется весь путь в интерфейсе:
// секция «ЗАБЛОКИРОВАННЫЕ», нажатие, PUT и исчезновение строки.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:voxnica/api/api_client.dart';
import 'package:voxnica/api/models.dart';
import 'package:voxnica/api/session_store.dart';
import 'package:voxnica/screens/friends_screen.dart';
import 'package:voxnica/state/app_controller.dart';
import 'package:voxnica/theme.dart';

http.Response json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('заблокированный виден во вкладке «Все» и разблокируется', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var blocked = true;
    http.Request? unblock;

    final api = await () async {
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
        client: MockClient((request) async {
          final path = request.url.path;

          if (request.method == 'GET' && path == '/api/v1/relationships') {
            return json({
              'friends': <Object>[],
              'incoming': <Object>[],
              'outgoing': <Object>[],
              'blocked': blocked
                  ? [
                      {
                        'user': {
                          'id': 'u2',
                          'username': 'bob',
                          'display_name': 'Bob',
                        },
                        'since': null,
                      },
                    ]
                  : <Object>[],
            });
          }

          if (request.method == 'GET' &&
              path == '/api/v1/relationships/presence') {
            return json({'presence': <String, String>{}});
          }

          if (request.method == 'PUT' &&
              path == '/api/v1/relationships/u2/block') {
            unblock = request;
            blocked = false;
            return http.Response('', 204);
          }

          throw StateError('неожиданный запрос: ${request.method} $path');
        }),
        store: store,
      );
      await client.restore();
      return client;
    }();

    final controller = AppController(api: api);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: FriendsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    // По умолчанию открыта вкладка «В сети» — переходим на «Все».
    await tester.tap(find.textContaining('Все'));
    await tester.pumpAndSettle();

    expect(find.text('ЗАБЛОКИРОВАННЫЕ'), findsOneWidget);
    expect(find.text('Разблокировать'), findsOneWidget);

    await tester.tap(find.text('Разблокировать'));
    await tester.pumpAndSettle();

    expect(unblock, isNotNull);
    expect(unblock!.body, '{"blocked":false}');
    expect(find.text('ЗАБЛОКИРОВАННЫЕ'), findsNothing);
    expect(find.text('Разблокирован'), findsOneWidget);
  });
}
