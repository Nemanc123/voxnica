import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/models.dart';

/// Состояние экрана «Друзья».
///
/// Отдельный контроллер, а не часть `AppController`: у друзей свой набор
/// загрузок (список, присутствие, поиск) и свои события шлюза. Так проще
/// тестировать и не раздувать основной контроллер.
class FriendsController extends ChangeNotifier {
  FriendsController(this._api);

  final ApiClient _api;

  FriendsView _view = const FriendsView.empty();
  Map<String, String> _presence = const {};
  List<UserSearchResult> _results = const [];

  bool _loading = false;
  bool _searching = false;
  String? _error;

  /// Последний запрос поиска: после блокировки или разблокировки результаты
  /// нужно перезапросить, иначе кнопка в списке остаётся прежней и кажется,
  /// что нажатие не сработало (нашлось при живом тесте 19.11.2026).
  String _query = '';

  FriendsView get view => _view;
  Map<String, String> get presence => _presence;
  List<UserSearchResult> get results => _results;
  bool get loading => _loading;
  bool get searching => _searching;
  String? get error => _error;

  int get pendingCount => _view.incoming.length;

  /// Сколько друзей сейчас в сети — для вкладки «В сети».
  int get onlineCount =>
      _view.friends.where((e) => _presence[e.user.id] == 'online').length;

  bool isOnline(String userID) => _presence[userID] == 'online';

  /// Загружает список связей и присутствие.
  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final view = await _api.relationships();
      final presence = await _api.friendsPresence();
      _view = view;
      _presence = presence;
    } catch (e) {
      _error = _describe(e);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Полный сброс состояния перед сменой аккаунта.
  ///
  /// Без него после выхода остаются результаты поиска прошлого пользователя:
  /// в «Добавить в друзья» видна чужая строка с кнопкой «Разблокировать»,
  /// и кажется, что предлагают разблокировать самого себя (P-48).
  void reset() {
    _view = const FriendsView.empty();
    _presence = const {};
    _results = const [];
    _query = '';
    _loading = false;
    _searching = false;
    _error = null;
    notifyListeners();
  }

  /// Очищает результаты поиска, не трогая список связей.
  void clearSearch() {
    _query = '';
    _results = const [];
    notifyListeners();
  }

  /// Поиск людей по логину или имени (минимум 2 символа).
  Future<void> search(String query) async {
    final q = query.trim();
    if (q.length < 2) {
      _query = '';
      _results = const [];
      notifyListeners();
      return;
    }

    _query = q;
    _searching = true;
    _error = null;
    notifyListeners();

    try {
      _results = await _api.searchUsers(q);
    } catch (e) {
      _error = _describe(e);
      _results = const [];
    } finally {
      _searching = false;
      notifyListeners();
    }
  }

  Future<bool> sendRequest(String userID) =>
      _action(() => _api.sendFriendRequest(userID), reload: true);

  Future<bool> accept(String userID) =>
      _action(() => _api.acceptFriendRequest(userID), reload: true);

  Future<bool> remove(String userID) =>
      _action(() => _api.removeRelationship(userID), reload: true);

  Future<bool> setBlocked(String userID, bool blocked) =>
      _action(() => _api.setBlocked(userID, blocked), reload: true);

  /// Общая обёртка: одна загрузка, одна ошибка, один перезапрос списка.
  Future<bool> _action(
    Future<void> Function() call, {
    required bool reload,
  }) async {
    _error = null;
    try {
      await call();
      if (reload) {
        final view = await _api.relationships();
        _view = view;
      }
      notifyListeners();
      // Связь изменилась — отношения в выдаче поиска тоже. Без перезапроса
      // кнопка «Разблокировать» остаётся на месте, будто действие не прошло.
      await _refreshSearch();
      return true;
    } catch (e) {
      _error = _describe(e);
      notifyListeners();
      return false;
    }
  }

  /// Перезапрашивает последнюю поисковую выдачу, если она открыта.
  ///
  /// Ошибку здесь глотаем: связь уже изменена, а список поиска обновится
  /// при следующем вводе — показывать два сообщения об ошибке незачем.
  Future<void> _refreshSearch() async {
    if (_query.isEmpty || _results.isEmpty) return;
    try {
      _results = await _api.searchUsers(_query);
      notifyListeners();
    } catch (_) {
      // см. комментарий выше
    }
  }

  /// События шлюза. Список перезапрашиваем: он маленький, а так не нужно
  /// вручную поддерживать четыре корзины в актуальном состоянии.
  void applyEvent(String type, Map<String, dynamic> data) {
    switch (type) {
      case 'FRIEND_REQUEST':
      case 'FRIEND_ACCEPT':
      case 'RELATIONSHIP_REMOVE':
        unawaited(load());
        break;
      case 'PRESENCE_UPDATE':
        final id = data['user_id'] as String?;
        final status = data['status'] as String?;
        if (id == null || status == null) return;
        _presence = {..._presence, id: status};
        notifyListeners();
        break;
    }
  }

  String _describe(Object error) {
    if (error is ApiException) return error.message;
    return 'Не удалось выполнить запрос';
  }
}
