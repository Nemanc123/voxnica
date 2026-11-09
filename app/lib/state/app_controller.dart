import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../gateway/gateway_client.dart';
import 'voice_controller.dart';

enum AppStage { loading, loggedOut, ready }

/// Состояние приложения: кто вошёл, какие серверы и каналы, что в ленте.
///
/// Один ChangeNotifier на всё приложение. Для MVP этого достаточно:
/// меньше движущихся частей, чем у провайдеров и кодогенерации.
class AppController extends ChangeNotifier {
  AppController({ApiClient? api}) : api = api ?? ApiClient() {
    voice = VoiceController(this.api);
  }

  final ApiClient api;
  late final VoiceController voice;

  AppStage _stage = AppStage.loading;
  User? _user;
  List<Guild> _guilds = const [];
  Guild? _guild;
  List<Channel> _channels = const [];
  Channel? _channel;
  List<Message> _messages = const [];
  Map<String, GuildMember> _members = const {};
  bool _busy = false;
  bool _loadingMessages = false;
  bool _sending = false;
  bool _hasMore = true;
  String? _error;

  GatewayClient? _gateway;
  StreamSubscription<GatewayEvent>? _eventSub;
  StreamSubscription<GatewayStatus>? _statusSub;
  GatewayStatus _gatewayStatus = GatewayStatus.disconnected;

  AppStage get stage => _stage;
  User? get user => _user;
  List<Guild> get guilds => _guilds;
  Guild? get guild => _guild;
  List<Channel> get channels => _channels;
  Channel? get channel => _channel;
  List<Message> get messages => _messages;
  String memberName(String? userId) {
    if (userId == null) return 'система';
    final member = _members[userId];
    if (member != null) return member.name;
    return userId.length >= 8 ? userId.substring(0, 8) : userId;
  }
  bool get busy => _busy;
  bool get loadingMessages => _loadingMessages;
  bool get sending => _sending;
  bool get hasMore => _hasMore;
  String? get error => _error;
  GatewayStatus get gatewayStatus => _gatewayStatus;

  List<Channel> get textChannels => _channels.where((c) => c.isText).toList();
  List<Channel> get voiceChannels => _channels.where((c) => c.isVoice).toList();

  Future<void> init() async {
    await api.restore();

    if (api.isAuthenticated) {
      _user = api.user;
      _stage = AppStage.ready;
      await _loadGuilds();
      _startGateway();
    } else {
      _stage = AppStage.loggedOut;
    }

    _busy = false;
    notifyListeners();
  }

  Future<bool> login(String login, String password) async {
    return _authenticate(() => api.login(login, password));
  }

  Future<bool> register({
    required String username,
    required String password,
    String? displayName,
  }) async {
    return _authenticate(() => api.register(
          username: username,
          password: password,
          displayName: displayName,
        ));
  }

  Future<bool> _authenticate(Future<AuthSession> Function() action) async {
    _busy = true;
    _error = null;
    notifyListeners();

    try {
      final session = await action();
      _user = session.user;
      _stage = AppStage.ready;
      await _loadGuilds();
      _startGateway();
      return true;
    } on ApiException catch (e) {
      _error = e.message;
      return false;
    } catch (_) {
      _error = 'Нет связи с сервером';
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    final gateway = _gateway;
    _gateway = null;
    await _eventSub?.cancel();
    await _statusSub?.cancel();
    await gateway?.dispose();

    await api.logout();

    _user = null;
    _guilds = const [];
    _guild = null;
    _channels = const [];
    _channel = null;
    _messages = const [];
    _members = const {};
    _error = null;
    _gatewayStatus = GatewayStatus.disconnected;
    _stage = AppStage.loggedOut;

    await voice.leave();
    notifyListeners();
  }

  Future<void> _loadGuilds() async {
    try {
      _guilds = await api.listGuilds();

      if (_guilds.isEmpty) {
        _guild = null;
        _channels = const [];
        _channel = null;
        _messages = const [];
        notifyListeners();
        return;
      }

      final currentId = _guild?.id;
      final selected = _guilds.firstWhere(
        (g) => g.id == currentId,
        orElse: () => _guilds.first,
      );

      await selectGuild(selected);
    } catch (e) {
      _error = _describe(e);
      notifyListeners();
    }
  }

  Future<void> selectGuild(Guild guild) async {
    _guild = guild;
    _channels = const [];
    _channel = null;
    _messages = const [];
    _members = const {};
    _error = null;
    notifyListeners();

    try {
      final detail = await api.guildDetail(guild.id);
      _channels = detail.channels;
      _members = await _loadMembers(guild.id);

      final first = _firstOrNull(_channels.where((c) => c.isText)) ??
          _firstOrNull(_channels.where((c) => c.isVoice));

      notifyListeners();

      if (first != null) {
        await selectChannel(first);
      }
    } catch (e) {
      _error = _describe(e);
      notifyListeners();
    }
  }

  Future<void> selectChannel(Channel channel) async {
    _channel = channel;
    _messages = const [];
    _hasMore = true;
    _error = null;
    notifyListeners();

    if (channel.isText) {
      await _loadMessages(reset: true);
    }
  }

  Future<void> _loadMessages({required bool reset}) async {
    final channel = _channel;
    if (channel == null || !channel.isText || _loadingMessages) return;

    if (!reset && !_hasMore) return;

    _loadingMessages = true;
    if (reset) {
      _messages = const [];
      _hasMore = true;
    }
    notifyListeners();

    final before = reset || _messages.isEmpty ? 0 : _messages.first.seq;

    try {
      final batch = await api.messages(channel.id, before: before);

      if (reset) {
        _messages = batch;
      } else {
        _messages = [...batch, ..._messages];
      }

      _hasMore = batch.length >= 50;
      _sortMessages();
      _markRead();
    } catch (e) {
      _error = _describe(e);
    } finally {
      _loadingMessages = false;
      notifyListeners();
    }
  }

  Future<void> loadOlder() => _loadMessages(reset: false);

  Future<void> sendMessage(String text) async {
    final channel = _channel;
    final content = text.trim();

    if (channel == null || !channel.isText || content.isEmpty || _sending) {
      return;
    }

    _sending = true;
    _error = null;
    notifyListeners();

    try {
      final message = await api.sendMessage(channel.id, content);
      _upsertMessage(message);
      _markRead();
    } catch (e) {
      _error = _describe(e);
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  /// Загружает файл в хранилище и отправляет сообщение с вложением.
  /// Сам файл через Go-сервер не идёт: presign → PUT в S3 → сообщение.
  Future<bool> sendWithAttachment({
    required String filename,
    required String contentType,
    required List<int> bytes,
    String text = '',
  }) async {
    final channel = _channel;
    if (channel == null || !channel.isText || _sending) return false;

    if (bytes.isEmpty) {
      _error = 'Файл пустой';
      notifyListeners();
      return false;
    }
    if (bytes.length > 25 << 20) {
      _error = 'Файл больше 25 МиБ';
      notifyListeners();
      return false;
    }

    _sending = true;
    _error = null;
    notifyListeners();

    try {
      final presign = await api.presignAttachment(
        channelId: channel.id,
        filename: filename,
        contentType: contentType,
        sizeBytes: bytes.length,
      );

      await api.uploadAttachment(
        presign,
        bytes,
        contentType: contentType,
      );

      final pending = PendingAttachment(
        storageKey: presign.storageKey,
        filename: filename,
        contentType: contentType,
        sizeBytes: bytes.length,
      );

      final message = await api.sendMessageWithAttachments(
        channel.id,
        text.trim(),
        [pending],
      );

      _upsertMessage(message);
      _markRead();
      return true;
    } catch (e) {
      _error = _describe(e);
      return false;
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  Future<bool> createGuild(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;

    _busy = true;
    _error = null;
    notifyListeners();

    try {
      final detail = await api.createGuild(trimmed);
      _guilds = await api.listGuilds();
      _guild = detail.guild;
      _channels = detail.channels;
      _members = await _loadMembers(detail.guild.id);

      final first = _firstOrNull(_channels.where((c) => c.isText)) ??
          _firstOrNull(_channels.where((c) => c.isVoice));

      notifyListeners();
      if (first != null) await selectChannel(first);
      return true;
    } catch (e) {
      _error = _describe(e);
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> createChannel(String name, String type) async {
    final guild = _guild;
    final trimmed = name.trim();
    if (guild == null || trimmed.isEmpty) return false;

    _busy = true;
    _error = null;
    notifyListeners();

    try {
      await api.createChannel(guildId: guild.id, name: trimmed, type: type);
      await selectGuild(guild);
      return true;
    } catch (e) {
      _error = _describe(e);
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> joinVoice(Channel channel) async {
    _channel = channel;
    _messages = const [];
    notifyListeners();
    await voice.join(channel.id);
  }

  Future<void> leaveVoice() => voice.leave();

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void _startGateway() {
    final gateway = GatewayClient(tokenProvider: api.freshAccessToken);
    _gateway = gateway;

    _eventSub = gateway.events.listen(_onGatewayEvent);
    _statusSub = gateway.statuses.listen((status) {
      _gatewayStatus = status;
      notifyListeners();
    });

    unawaited(gateway.connect());
  }

  void _onGatewayEvent(GatewayEvent event) {
    switch (event.type) {
      case 'MESSAGE_CREATE':
      case 'MESSAGE_UPDATE':
        {
          final data = event.data;
          if (data is Map<String, dynamic>) {
            final message = Message.fromJson(data);
            if (message.channelId == _channel?.id) {
              _upsertMessage(message);
              _markRead();
            }
          }
          break;
        }
      case 'MESSAGE_DELETE':
        {
          final data = event.data;
          if (data is Map<String, dynamic>) {
            final id = data['id'] as String?;
            if (id != null) {
              _messages = _messages.where((m) => m.id != id).toList();
              notifyListeners();
            }
          }
          break;
        }
      case 'VOICE_STATE_UPDATE':
        {
          final data = event.data;
          if (data is Map<String, dynamic> &&
              data['channel_id'] == voice.channelId) {
            unawaited(voice.refreshParticipants());
          }
          break;
        }
    }
  }

  void _upsertMessage(Message message) {
    final index = _messages.indexWhere((m) => m.id == message.id);
    if (index >= 0) {
      final copy = [..._messages];
      copy[index] = message;
      _messages = copy;
    } else {
      _messages = [..._messages, message];
    }

    _sortMessages();
    notifyListeners();
  }

  void _sortMessages() {
    final sorted = [..._messages]..sort((a, b) => a.seq.compareTo(b.seq));
    _messages = sorted;
  }

  void _markRead() {
    final channel = _channel;
    if (channel == null || !channel.isText || _messages.isEmpty) return;

    final lastSeq = _messages.last.seq;
    unawaited(_markReadAsync(channel.id, lastSeq));
  }

  Future<void> _markReadAsync(String channelId, int seq) async {
    try {
      await api.markRead(channelId, seq);
    } catch (_) {
      // Непрочитанные обновятся при следующем заходе.
    }
  }

  String _describe(Object error) {
    if (error is ApiException) return error.message;
    return 'Нет связи с сервером';
  }

  T? _firstOrNull<T>(Iterable<T> items) {
    for (final item in items) {
      return item;
    }
    return null;
  }

  Future<Map<String, GuildMember>> _loadMembers(String guildId) async {
    try {
      final list = await api.members(guildId);
      return {for (final member in list) member.userId: member};
    } catch (_) {
      // Без имён лента работает, показывая префикс UUID.
      return const {};
    }
  }

  @override
  void dispose() {
    final eventSub = _eventSub;
    final statusSub = _statusSub;
    final gateway = _gateway;

    if (eventSub != null) unawaited(eventSub.cancel());
    if (statusSub != null) unawaited(statusSub.cancel());
    if (gateway != null) unawaited(gateway.dispose());

    voice.dispose();
    super.dispose();
  }
}
