import 'dart:async';

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
  EventsListener<RoomEvent>? _listener;
  String? _channelId;
  List<VoiceParticipant> _participants = const [];
  Set<String> _speaking = const {};
  bool _connecting = false;
  bool _micEnabled = false;
  bool _deafened = false;
  String? _error;

  String? get channelId => _channelId;
  List<VoiceParticipant> get participants => _participants;
  bool get connecting => _connecting;
  bool get micEnabled => _micEnabled;
  bool get deafened => _deafened;
  bool get connected => _room != null;
  String? get error => _error;

  bool isSpeaking(String userId) => _speaking.contains(userId);

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
      _listener = room.createListener()
        ..on<ActiveSpeakersChangedEvent>((event) {
          _speaking = event.speakers.map((p) => p.identity).toSet();
          notifyListeners();
        })
        ..on<TrackSubscribedEvent>((event) async {
          // Пока звук выключен, новые треки тоже не должны играть.
          if (_deafened && event.track is RemoteAudioTrack) {
            await event.track.stop();
          }
        });

      if (info.canPublish) {
        await room.localParticipant?.setMicrophoneEnabled(true);
        _micEnabled = true;
      }

      await refreshParticipants();
    } catch (e) {
      _error = 'Не удалось подключиться: $e';
      await _listener?.dispose();
      _listener = null;
      await _room?.disconnect();
      _room = null;
      _micEnabled = false;
      _deafened = false;
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

    // Включение микрофона автоматически снимает глушение.
    if (next && _deafened) {
      _deafened = false;
      await _setRemoteAudioEnabled(true);
    }

    await _pushState();
    notifyListeners();
  }

  Future<void> toggleDeafen() async {
    final room = _room;
    if (room == null) return;

    final next = !_deafened;
    _deafened = next;

    if (next && _micEnabled) {
      await room.localParticipant?.setMicrophoneEnabled(false);
      _micEnabled = false;
    }

    await _setRemoteAudioEnabled(!next);
    await _pushState();
    notifyListeners();
  }

  Future<void> _setRemoteAudioEnabled(bool enabled) async {
    final room = _room;
    if (room == null) return;

    for (final participant in room.remoteParticipants.values) {
      for (final publication in participant.audioTrackPublications) {
        final track = publication.track;
        if (track is RemoteAudioTrack) {
          if (enabled) {
            await track.start();
          } else {
            await track.stop();
          }
        }
      }
    }
  }

  Future<void> _pushState() async {
    final id = _channelId;
    if (id == null) return;

    try {
      await api.voiceState(
        id,
        selfMute: !_micEnabled,
        selfDeaf: _deafened,
      );
    } catch (_) {
      // Состояние — не критично для самого разговора.
    }
  }

  Future<void> leave() async {
    final room = _room;
    _room = null;
    _listener?.dispose();
    _listener = null;
    _channelId = null;
    _participants = const [];
    _speaking = const {};
    _micEnabled = false;
    _deafened = false;
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
    _listener?.dispose();
    _listener = null;
    room?.disconnect();
    room?.dispose();
    super.dispose();
  }
}
