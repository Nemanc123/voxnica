import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_controller.dart';
import '../state/friends_controller.dart';
import '../theme.dart';

/// Экран «Друзья»: список, заявки, поиск людей.
///
/// Отдельный маршрут поверх домашнего экрана: серверы и личные диалоги
/// остаются на месте, а друзья открываются кнопкой в панели серверов.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final _search = TextEditingController();
  String _tab = 'online';

  FriendsController get _friends => widget.controller.friends;

  @override
  void initState() {
    super.initState();
    // Список грузим при открытии: до этого экрана он не нужен.
    _friends.load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(backgroundColor: kSidebar, title: const Text('Друзья')),
      body: ListenableBuilder(
        listenable: _friends,
        builder: (context, _) {
          final error = _friends.error;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _tabChip('online', 'В сети ${_friends.onlineCount}'),
                    _tabChip('all', 'Все ${_friends.view.friends.length}'),
                    _tabChip(
                      'pending',
                      'Ожидание ${_friends.pendingCount}',
                      highlight: _friends.pendingCount > 0,
                    ),
                    _tabChip('add', 'Добавить в друзья'),
                  ],
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    error,
                    style: const TextStyle(color: kDanger, fontSize: 12),
                  ),
                ),
              Expanded(child: _body()),
            ],
          );
        },
      ),
    );
  }

  Widget _tabChip(String id, String label, {bool highlight = false}) {
    final selected = _tab == id;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        setState(() => _tab = id);
        if (id == 'pending' || id == 'online' || id == 'all') {
          _friends.load();
        }
      },
      labelStyle: TextStyle(
        fontSize: 12,
        color: highlight && !selected ? kOnline : null,
      ),
    );
  }

  Widget _body() {
    if (_friends.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    switch (_tab) {
      case 'add':
        return _addTab();
      case 'pending':
        return _pendingTab();
      case 'online':
        final online = _friends.view.friends
            .where((e) => _friends.isOnline(e.user.id))
            .toList();
        if (online.isEmpty) {
          return const _Empty(
            text:
                'Никого нет в сети. Друзья появятся здесь, когда откроют '
                'приложение.',
          );
        }
        return _friendsList(online);
      default:
        return _allTab();
    }
  }

  /// Вкладка «Все»: друзья, ниже — заблокированные.
  ///
  /// Заблокированные раньше были видны только через поиск по логину:
  /// снять блокировку можно было, лишь вспомнив, кого блокировал.
  Widget _allTab() {
    final friends = _friends.view.friends;
    final blocked = _friends.view.blocked;

    if (friends.isEmpty && blocked.isEmpty) {
      return const _Empty(
        text: 'Пока нет друзей. Перейдите на вкладку «Добавить в друзья».',
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (friends.isNotEmpty)
          ..._sorted(friends).map((e) => _friendTile(e.user)),
        if (blocked.isNotEmpty) ...[
          const _GroupLabel('ЗАБЛОКИРОВАННЫЕ'),
          ...blocked.map(_blockedTile),
        ],
      ],
    );
  }

  /// В сети — сверху, затем по имени.
  List<RelationshipEntry> _sorted(List<RelationshipEntry> entries) {
    return [...entries]..sort((a, b) {
      final ao = _friends.isOnline(a.user.id) ? 0 : 1;
      final bo = _friends.isOnline(b.user.id) ? 0 : 1;
      if (ao != bo) return ao - bo;
      return a.user.name.toLowerCase().compareTo(b.user.name.toLowerCase());
    });
  }

  Widget _friendsList(List<RelationshipEntry> entries) {
    final sorted = _sorted(entries);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        final entry = sorted[index];
        return _friendTile(entry.user);
      },
    );
  }

  Widget _blockedTile(RelationshipEntry entry) {
    final user = entry.user;
    return ListTile(
      leading: _avatar(user),
      title: Text(user.name),
      subtitle: const Text(
        'Заблокирован',
        style: TextStyle(fontSize: 12, color: kTextMuted),
      ),
      trailing: TextButton(
        onPressed: () => _run(
          () => _friends.setBlocked(user.id, false),
          'Не удалось разблокировать',
          success: 'Разблокирован',
        ),
        child: const Text('Разблокировать'),
      ),
    );
  }

  Widget _friendTile(User user) {
    final online = _friends.isOnline(user.id);
    return ListTile(
      leading: _avatar(user),
      title: Text(user.name),
      subtitle: Text(
        online ? 'В сети' : 'Неактивен',
        style: TextStyle(fontSize: 12, color: online ? kOnline : kTextMuted),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Написать',
            icon: const Icon(Icons.chat_bubble_outline, size: 20),
            onPressed: () => _openDm(user),
          ),
          IconButton(
            tooltip: 'Позвонить',
            icon: const Icon(Icons.call, size: 20),
            onPressed: () => _call(user),
          ),
          PopupMenuButton<String>(
            tooltip: 'Ещё',
            onSelected: (action) => _friendAction(action, user),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'remove', child: Text('Удалить из друзей')),
              PopupMenuItem(value: 'block', child: Text('Заблокировать')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pendingTab() {
    final incoming = _friends.view.incoming;
    final outgoing = _friends.view.outgoing;

    if (incoming.isEmpty && outgoing.isEmpty) {
      return const _Empty(text: 'Нет заявок — ни входящих, ни исходящих.');
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (incoming.isNotEmpty) const _GroupLabel('ВХОДЯЩИЕ'),
        ...incoming.map(
          (e) => ListTile(
            leading: _avatar(e.user),
            title: Text(e.user.name),
            subtitle: const Text('Хочет добавить вас в друзья'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => _run(
                    () => _friends.accept(e.user.id),
                    'Не удалось принять заявку',
                  ),
                  child: const Text('Принять'),
                ),
                IconButton(
                  tooltip: 'Отклонить',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => _run(
                    () => _friends.remove(e.user.id),
                    'Не удалось отклонить заявку',
                  ),
                ),
              ],
            ),
          ),
        ),
        if (outgoing.isNotEmpty) const _GroupLabel('ИСХОДЯЩИЕ'),
        ...outgoing.map(
          (e) => ListTile(
            leading: _avatar(e.user),
            title: Text(e.user.name),
            subtitle: const Text('Заявка отправлена, ждём ответа'),
            trailing: TextButton(
              onPressed: () => _run(
                () => _friends.remove(e.user.id),
                'Не удалось отменить заявку',
              ),
              child: const Text('Отменить'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _addTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Логин или имя',
                    helperText: 'Минимум 2 символа',
                  ),
                  onSubmitted: (value) => _friends.search(value),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _friends.searching
                    ? null
                    : () => _friends.search(_search.text),
                child: Text(_friends.searching ? 'Ищем…' : 'Найти'),
              ),
            ],
          ),
        ),
        if (_friends.results.isEmpty)
          const Expanded(
            child: _Empty(
              text: 'Введите логин человека, которого хотите добавить.',
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: _friends.results.length,
              itemBuilder: (context, index) {
                final result = _friends.results[index];
                return ListTile(
                  leading: _avatar(
                    User(
                      id: result.id,
                      username: result.username,
                      displayName: result.displayName,
                    ),
                  ),
                  title: Text(result.name),
                  subtitle: Text(
                    '@${result.username}',
                    style: const TextStyle(fontSize: 11, color: kTextMuted),
                  ),
                  trailing: _searchAction(result),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _searchAction(UserSearchResult result) {
    switch (result.relation) {
      case 'friend':
        return TextButton(
          onPressed: () => _openDm(
            User(
              id: result.id,
              username: result.username,
              displayName: result.displayName,
            ),
          ),
          child: const Text('Написать'),
        );
      case 'incoming':
        return TextButton(
          onPressed: () => _run(
            () => _friends.accept(result.id),
            'Не удалось принять заявку',
          ),
          child: const Text('Принять'),
        );
      case 'outgoing':
        return const Text('Заявка отправлена', style: TextStyle(fontSize: 12));
      case 'blocked':
        return TextButton(
          onPressed: () => _run(
            () => _friends.setBlocked(result.id, false),
            'Не удалось разблокировать',
            success: 'Разблокирован',
          ),
          child: const Text('Разблокировать'),
        );
      default:
        return FilledButton(
          onPressed: () => _run(
            () => _friends.sendRequest(result.id),
            'Не удалось отправить заявку',
          ),
          child: const Text('Добавить'),
        );
    }
  }

  Widget _avatar(User user) {
    final online = _friends.isOnline(user.id);
    return Stack(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: kAccent,
          child: Text(
            user.name.isEmpty ? '?' : user.name[0].toUpperCase(),
            style: const TextStyle(fontSize: 14),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: online ? kOnline : kTextMuted,
              shape: BoxShape.circle,
              border: Border.all(color: kBackground, width: 2),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _friendAction(String action, User user) async {
    switch (action) {
      case 'remove':
        await _run(
          () => _friends.remove(user.id),
          'Не удалось удалить из друзей',
        );
      case 'block':
        await _run(
          () => _friends.setBlocked(user.id, true),
          'Не удалось заблокировать',
          success: 'Заблокирован',
        );
    }
  }

  Future<void> _run(
    Future<bool> Function() action,
    String failure, {
    String? success,
  }) async {
    final ok = await action();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(_friends.error ?? failure)),
      );
    } else if (success != null) {
      // Без подтверждения успешное действие выглядит как «ничего не вышло»,
      // особенно когда строка в списке не исчезает.
      messenger.showSnackBar(SnackBar(content: Text(success)));
    }
  }

  Future<void> _openDm(User user) async {
    final ok = await widget.controller.startDm(user.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.controller.error ?? 'Не удалось открыть диалог'),
        ),
      );
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _call(User user) async {
    final ok = await widget.controller.startDm(user.id);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.controller.error ?? 'Не удалось открыть диалог'),
        ),
      );
      return;
    }

    final channel = widget.controller.channel;
    if (channel != null) await widget.controller.startDmCall(channel);
    if (mounted) Navigator.of(context).pop();
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: kTextMuted),
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: kTextMuted,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
