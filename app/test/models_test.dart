import 'package:flutter_test/flutter_test.dart';

import 'package:voxnica/api/models.dart';

void main() {
  test('AuthSession разбирает пользователя и срок токена', () {
    final session = AuthSession.fromJson({
      'user': {
        'id': 'u1',
        'username': 'alice',
        'display_name': 'Алиса',
      },
      'access_token': 'a',
      'refresh_token': 'r',
      'expires_in': 900,
    });

    expect(session.user.name, 'Алиса');
    expect(session.expiresAt, isNotNull);
  });

  test('GuildDetail отбрасывает категории', () {
    final detail = GuildDetail.fromJson({
      'guild': {'id': 'g1', 'name': 'Сервер'},
      'channels': [
        {'id': 'c1', 'name': 'general', 'type': 'text'},
        {'id': 'c2', 'name': 'Голосовой', 'type': 'voice'},
        {'id': 'c3', 'name': 'Текст', 'type': 'category'},
      ],
    });

    expect(detail.channels.length, 2);
    expect(detail.channels.first.isText, isTrue);
    expect(detail.channels.last.isVoice, isTrue);
  });

  test('Message разбирает вложения и время', () {
    final message = Message.fromJson({
      'id': 'm1',
      'seq': 42,
      'channel_id': 'c1',
      'author_id': '12345678-aaaa',
      'content': 'привет',
      'created_at': '2026-11-09T12:00:00Z',
      'attachments': [
        {
          'id': 'a1',
          'filename': 'отчёт.pdf',
          'content_type': 'application/pdf',
          'size_bytes': 2048,
          'storage_key': 'attachments/c1/x.pdf',
        },
      ],
    });

    expect(message.seq, 42);
    expect(message.authorLabel, '12345678');
    expect(message.attachments.single.filename, 'отчёт.pdf');
    expect(message.attachments.single.sizeLabel, '2.0 КБ');
  });

  test('GuildMember берёт ник, потом display_name, потом username', () {
    final withNickname = GuildMember.fromJson({
      'user_id': 'u1',
      'username': 'alice',
      'display_name': 'Алиса',
      'nickname': 'Лиса',
    });
    final withoutNickname = GuildMember.fromJson({
      'user_id': 'u2',
      'username': 'bob',
      'display_name': 'Боб',
    });

    expect(withNickname.name, 'Лиса');
    expect(withoutNickname.name, 'Боб');
  });
}
