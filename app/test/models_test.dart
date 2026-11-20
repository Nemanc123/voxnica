import 'package:flutter_test/flutter_test.dart';

import 'package:voxnica/api/models.dart';

void main() {
  test('AuthSession разбирает пользователя и срок токена', () {
    final session = AuthSession.fromJson({
      'user': {'id': 'u1', 'username': 'alice', 'display_name': 'Алиса'},
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

  test('DmChannel берёт имя собеседника, а не своё', () {
    final dm = DmChannel.fromJson({
      'id': 'd1',
      'type': 'dm',
      'recipients': [
        {'user_id': 'me', 'username': 'me'},
        {'user_id': 'other', 'username': 'bob', 'display_name': 'Боб'},
      ],
    });

    expect(dm.title('me'), 'Боб');
    expect(dm.title('other'), 'me');
  });

  test('DmChannel группы: имя, участники и сокращение списка', () {
    final group = DmChannel.fromJson({
      'id': 'g1',
      'type': 'group_dm',
      'recipients': [
        {'user_id': 'me', 'username': 'me'},
        {'user_id': 'u1', 'username': 'anna'},
        {'user_id': 'u2', 'username': 'bob'},
        {'user_id': 'u3', 'username': 'carl'},
        {'user_id': 'u4', 'username': 'dave'},
      ],
    });

    expect(group.isGroup, isTrue);
    expect(group.title('me'), 'anna, bob, carl +1');

    final named = DmChannel.fromJson({
      'id': 'g2',
      'type': 'group_dm',
      'name': 'Проект',
      'recipients': [
        {'user_id': 'me', 'username': 'me'},
        {'user_id': 'u1', 'username': 'anna'},
        {'user_id': 'u2', 'username': 'bob'},
      ],
    });
    expect(named.title('me'), 'Проект');
  });
}
