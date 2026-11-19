// Разбор ответов API друзей: формат проверяем на реальных примерах.

import 'package:flutter_test/flutter_test.dart';

import 'package:voxnica/api/models.dart';

void main() {
  test('FriendsView разбирает четыре корзины и имена', () {
    final view = FriendsView.fromJson({
      'friends': [
        {
          'user': {'id': 'u1', 'username': 'pehkin12'},
          'since': '2026-11-19T10:00:00Z',
        },
      ],
      'incoming': [
        {
          'user': {'id': 'u2', 'username': 'boyar', 'display_name': 'Бояр'},
          'since': '2026-11-19T11:00:00Z',
        },
      ],
      'outgoing': [
        {
          'user': {'id': 'u3', 'username': 'test3'},
          'since': '2026-11-19T12:00:00Z',
        },
      ],
      'blocked': [
        {
          'user': {'id': 'u4', 'username': 'spam'},
          'since': '2026-11-19T13:00:00Z',
        },
      ],
    });

    expect(view.friends, hasLength(1));
    expect(view.friends.first.user.username, 'pehkin12');
    expect(view.incoming.first.user.name, 'Бояр');
    expect(view.outgoing.first.user.id, 'u3');
    expect(view.blocked.first.user.id, 'u4');
    expect(view.friends.first.since, isNotNull);
    expect(view.isEmpty, isFalse);
  });

  test('FriendsView терпит пустой ответ', () {
    final view = FriendsView.fromJson(const {});

    expect(view.isEmpty, isTrue);
    expect(view.friends, isEmpty);
    expect(view.incoming, isEmpty);
  });

  test('UserSearchResult разбирает отношение', () {
    final result = UserSearchResult.fromJson({
      'id': 'u1',
      'username': 'pehkin12',
      'display_name': 'Пех',
      'relation': 'outgoing',
    });

    expect(result.name, 'Пех');
    expect(result.relation, 'outgoing');
  });

  test('UserSearchResult без display_name использует логин', () {
    final result = UserSearchResult.fromJson({
      'id': 'u2',
      'username': 'test3',
      'relation': 'none',
    });

    expect(result.name, 'test3');
    expect(result.displayName, isNull);
  });
}
