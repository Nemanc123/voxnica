import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../api/api_client.dart';
import '../api/models.dart';

/// Состояние голосового подключения.
///
/// Токен и адрес выдаёт наш API, дальше клиент соединяется с LiveKit
/// напрямую. Список участников берём из БД через API: LiveKit знает
/// только тех, кто уже в комнате, а нам нужны имена и статусы.
class VoiceController extends ChangeNotifier {
  VoiceController(this.api);

  final ApiClient api;

  Room? _room;
  String? _channelId;
  List<VoiceParticipant> _participants = const [];
  bool _connecting = false;
  bool _micEnabled = false;
  String? _error;

  String? get channelId => _channelId;
  List<VoiceParticipant> get participants => _participants;
  bool get connecting => _connecting;
  bool get micEnabled => _micEnabled;
  bool get connected => _room != null;
  String? get error => _error;

  Future<void> join(String channelId) async {
    await leave();

    _channelId = channelId;
    _connecting = true;
    _error = null;
    notifyListeners();

    try {
      final info = await api.voiceJoin(channelId);
      final room = Room();
      await room.connect(info.url, info.token);

      _room = room;

      if (info.canPublish) {
        await room.localParticipant?.setMicrophoneEnabled(true);
        _micEnabled = true;
      }

      await refreshParticipants();
    } catch (e) {
      _error = 'Не удалось подключиться: $e';
      await _room?.disconnect();
      _room = null;
      _micEnabled = false;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  Future<void> refreshParticipants() async {
    final id = _channelId;
    if (id == null) return;

    try {
      _participants = await api.voiceParticipants(id);
      notifyListeners();
    } catch (_) {
      // Список обновится при следующем событии.
    }
  }

  Future<void> toggleMicrophone() async {
    final room = _room;
    if (room == null) return;

    final next = !_micEnabled;
    await room.localParticipant?.setMicrophoneEnabled(next);
    _micEnabled = next;
    notifyListeners();
  }

  Future<void> leave() async {
    final room = _room;
    _room = null;
    _channelId = null;
    _participants = const [];
    _micEnabled = false;
    _error = null;

    if (room != null) {
      await room.disconnect();
      await room.dispose();
    }

    notifyListeners();
  }

  @override
  void dispose() {
    final room = _room;
    _room = null;
    room?.disconnect();
    room?.dispose();
    super.dispose();
  }
}
