import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:voxnica/api/api_client.dart';
import 'package:voxnica/api/models.dart';
import 'package:voxnica/api/session_store.dart';
import 'package:voxnica/gateway/gateway_client.dart';

/// Живой тест клиента против настоящего сервера.
///
/// Запуск:
///   flutter test test/live_api_test.dart \
///     --dart-define=E2E_API_URL=http://HOST:8080/api/v1
///
/// Без E2E_API_URL тест пропускается.
const _base = String.fromEnvironment('E2E_API_URL');

void main() {
  test('регистрация, сервер, сообщение и голосовой токен', () async {
    if (_base.isEmpty) {
      markTestSkipped('E2E_API_URL не задан');
      return;
    }

    final suffix = DateTime.now().microsecondsSinceEpoch;
    final api = ApiClient(
      baseUrl: _base,
      store: SessionStore.memory(),
    );

    final session = await api.register(
      username: 'e2e$suffix',
      password: 'very-long-password',
      displayName: 'Клиент',
    );
    expect(session.user.username, startsWith('e2e'));

    final detail = await api.createGuild('Проверка клиента');
    expect(detail.channels.length, greaterThanOrEqualTo(2));

    final members = await api.members(detail.guild.id);
    expect(members, hasLength(1));
    expect(members.single.username, startsWith('e2e'));

    final text = detail.channels.firstWhere((c) => c.isText);
    final voice = detail.channels.firstWhere((c) => c.isVoice);

    final sent = await api.sendMessage(text.id, 'привет из Flutter');
    expect(sent.content, 'привет из Flutter');

    final history = await api.messages(text.id);
    expect(history.any((m) => m.id == sent.id), isTrue);

    final presign = await api.presignAttachment(
      channelId: text.id,
      filename: 'live.txt',
      contentType: 'text/plain',
      sizeBytes: 5,
    );
    await api.uploadAttachment(
      presign,
      utf8.encode('hello'),
      contentType: 'text/plain',
    );
    final withFile = await api.sendMessageWithAttachments(
      text.id,
      'файл',
      [
        PendingAttachment(
          storageKey: presign.storageKey,
          filename: 'live.txt',
          contentType: 'text/plain',
          sizeBytes: 5,
        ),
      ],
    );
    expect(withFile.attachments.single.filename, 'live.txt');

    final join = await api.voiceJoin(voice.id);
    expect(join.token, isNotEmpty);
    expect(join.room, voice.id);
    expect(join.canPublish, isTrue);

    await api.voiceState(voice.id, selfMute: true, selfDeaf: true);

    final participants = await api.voiceParticipants(voice.id);
    expect(participants, isEmpty);
  });

  test('WebSocket присылает READY и MESSAGE_CREATE', () async {
    if (_base.isEmpty) {
      markTestSkipped('E2E_API_URL не задан');
      return;
    }

    final suffix = DateTime.now().microsecondsSinceEpoch;
    final api = ApiClient(
      baseUrl: _base,
      store: SessionStore.memory(),
    );

    await api.register(
      username: 'ws$suffix',
      password: 'very-long-password',
    );

    final detail = await api.createGuild('WebSocket');
    final text = detail.channels.firstWhere((c) => c.isText);

    final ready = Completer<void>();
    final received = Completer<Message>();

    final wsBase = _base
        .replaceFirst('http://', 'ws://')
        .replaceFirst('https://', 'wss://')
        .replaceFirst(RegExp(r'/api/v1/?$'), '');

    final gateway = GatewayClient(
      url: '$wsBase/gateway',
      tokenProvider: api.freshAccessToken,
    );

    final subscription = gateway.events.listen((event) {
      if (event.type == 'READY' && !ready.isCompleted) {
        ready.complete();
      }
      if (event.type == 'MESSAGE_CREATE' &&
          !received.isCompleted &&
          event.data is Map<String, dynamic>) {
        final message = Message.fromJson(event.data as Map<String, dynamic>);
        if (message.channelId == text.id) received.complete(message);
      }
    });

    await gateway.connect();
    await ready.future.timeout(const Duration(seconds: 5));

    await api.sendMessage(text.id, 'привет через сокет');

    final message = await received.future.timeout(const Duration(seconds: 5));
    expect(message.content, 'привет через сокет');

    await subscription.cancel();
    await gateway.dispose();
  });
}
