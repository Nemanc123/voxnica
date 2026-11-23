import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';

import '../api/api_client.dart';
import '../api/models.dart';

/// Состояние голосового подключения.
///
/// Токен и адрес выдаёт наш API, дальше клиент соединяется с LiveKit
/// напрямую. Список участников берём из БД через API: LiveKit знает
/// только тех, кто уже в комнате, а нам нужны имена и статусы.

/// Один видеотрек в сетке: локальная камера или камера участника.
class VideoTile {
  const VideoTile({
    required this.track,
    required this.name,
    required this.isLocal,
  });

  final VideoTrack track;
  final String name;
  final bool isLocal;
}

class VoiceController extends ChangeNotifier {
  VoiceController(this.api);

  /// Канал к MainActivity: foreground service, без которого Android 14+
  /// не разрешает захват экрана.
  static const MethodChannel _screenShareChannel = MethodChannel(
    'voxnica/screen_share',
  );

  final ApiClient api;

  Room? _room;
  EventsListener<RoomEvent>? _listener;
  String? _channelId;
  List<VoiceParticipant> _participants = const [];
  Set<String> _speaking = const {};
  bool _connecting = false;
  bool _micEnabled = false;
  bool _deafened = false;
  bool _cameraEnabled = false;
  bool _screenSharing = false;
  bool _canVideo = false;
  bool _canScreenShare = false;
  String? _error;

  /// Обработка голоса (шумоподавление + АРУ). Можно выключить для сравнения:
  /// агрессивная обработка делает голос «ватным» и «металлическим».
  bool _audioProcessing = true;

  /// Уровень своего микрофона 0..1 — для индикатора «вас слышно».
  double _micLevel = 0;

  List<MediaDevice> _audioInputs = const [];
  String? _selectedMicId;

  /// Настройки захвата звука.
  ///
  /// Явно, а не «как в SDK по умолчанию»: по умолчанию включены
  /// voiceIsolation и typingNoiseDetection, которые на Android и в
  /// эмуляторе дают металлический призвук; highPassFilter наоборот
  /// полезен — убирает гул стола и вентилятора.
  AudioCaptureOptions get _captureOptions => AudioCaptureOptions(
    deviceId: _selectedMicId,
    echoCancellation: true,
    noiseSuppression: _audioProcessing,
    autoGainControl: _audioProcessing,
    highPassFilter: true,
    voiceIsolation: false,
    typingNoiseDetection: false,
  );

  String? get channelId => _channelId;
  List<VoiceParticipant> get participants => _participants;
  bool get connecting => _connecting;
  bool get micEnabled => _micEnabled;
  bool get deafened => _deafened;
  bool get cameraEnabled => _cameraEnabled;
  bool get screenSharing => _screenSharing;
  bool get canVideo => _canVideo;
  bool get canScreenShare => _canScreenShare;
  bool get connected => _room != null;
  String? get error => _error;
  bool get audioProcessing => _audioProcessing;
  double get micLevel => _micLevel;
  List<MediaDevice> get audioInputs => _audioInputs;
  String? get selectedMicId => _selectedMicId;

  /// Локальная камера — для превью в сетке.
  LocalVideoTrack? get localCameraTrack {
    final participant = _room?.localParticipant;
    if (participant == null) return null;

    for (final publication in participant.videoTrackPublications) {
      if (publication.source == TrackSource.camera &&
          publication.track is LocalVideoTrack) {
        return publication.track as LocalVideoTrack;
      }
    }
    return null;
  }

  /// Камеры других участников.
  List<VideoTrack> get remoteCameraTracks {
    final out = <VideoTrack>[];
    final participants = _room?.remoteParticipants.values;
    if (participants == null) return out;

    for (final participant in participants) {
      for (final publication in participant.videoTrackPublications) {
        final track = publication.track;
        if (publication.source == TrackSource.camera && track != null) {
          out.add(track);
        }
      }
    }
    return out;
  }

  /// Камеры для сетки: локальная и чужие, с именами.
  List<VideoTile> get cameraTiles {
    final out = <VideoTile>[];

    final local = localCameraTrack;
    if (local != null) {
      out.add(VideoTile(track: local, name: 'Вы', isLocal: true));
    }

    final participants = _room?.remoteParticipants.values;
    if (participants == null) return out;

    for (final participant in participants) {
      for (final publication in participant.videoTrackPublications) {
        final track = publication.track;
        if (publication.source == TrackSource.camera && track != null) {
          out.add(
            VideoTile(
              track: track,
              name: participant.name.isEmpty
                  ? participant.identity
                  : participant.name,
              isLocal: false,
            ),
          );
        }
      }
    }

    return out;
  }

  /// Демонстрация экрана: своя или чужая.
  VideoTrack? get screenShareTrack {
    final local = _room?.localParticipant;
    if (local != null) {
      for (final publication in local.videoTrackPublications) {
        if (publication.source == TrackSource.screenShareVideo &&
            publication.track is VideoTrack) {
          return publication.track as VideoTrack;
        }
      }
    }

    final participants = _room?.remoteParticipants.values;
    if (participants == null) return null;

    for (final participant in participants) {
      for (final publication in participant.videoTrackPublications) {
        final track = publication.track;
        if (publication.source == TrackSource.screenShareVideo &&
            track is VideoTrack) {
          return track;
        }
      }
    }
    return null;
  }

  bool isSpeaking(String userId) => _speaking.contains(userId);

  Future<void> join(String channelId) async {
    await leave();

    _channelId = channelId;
    _connecting = true;
    _error = null;
    notifyListeners();

    try {
      final info = await api.voiceJoin(channelId);
      final room = Room(
        roomOptions: RoomOptions(
          defaultAudioCaptureOptions: _captureOptions,
          adaptiveStream: true,
          dynacast: true,
        ),
      );
      await room.connect(info.url, info.token);

      _room = room;
      _canVideo = info.canVideo;
      _canScreenShare = info.canScreenShare;
      _listener = room.createListener()
        ..on<ActiveSpeakersChangedEvent>((event) {
          _speaking = event.speakers.map((p) => p.identity).toSet();

          // Уровень своего микрофона: LiveKit присылает его в этом же
          // событии для говорящих. Если нас нет в списке — тишина.
          final selfId = room.localParticipant?.identity;
          _micLevel = 0;
          for (final speaker in event.speakers) {
            if (speaker.identity == selfId) {
              _micLevel = speaker.audioLevel.clamp(0.0, 1.0);
              break;
            }
          }
          notifyListeners();
        })
        ..on<TrackSubscribedEvent>((event) async {
          // Пока звук выключен, новые треки тоже не должны играть.
          if (_deafened && event.track is RemoteAudioTrack) {
            await event.track.stop();
          }
          notifyListeners();
        })
        ..on<TrackUnsubscribedEvent>((_) => notifyListeners());

      if (info.canSpeak) {
        await room.localParticipant?.setMicrophoneEnabled(
          true,
          audioCaptureOptions: _captureOptions,
        );
        _micEnabled = true;
        await loadAudioInputs();
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

  /// Список микрофонов устройства. Заполняется при входе в канал.
  Future<void> loadAudioInputs() async {
    try {
      _audioInputs = await Hardware.instance.audioInputs();
      _selectedMicId ??= Hardware.instance.selectedAudioInput?.deviceId;
    } catch (_) {
      _audioInputs = const [];
    }
    notifyListeners();
  }

  /// Переключить микрофон (гарнитура вместо встроенного).
  Future<void> selectMicrophone(MediaDevice device) async {
    _selectedMicId = device.deviceId;
    final room = _room;
    if (room != null) {
      try {
        await room.setAudioInputDevice(device);
        if (_micEnabled) {
          await room.localParticipant?.setMicrophoneEnabled(
            true,
            audioCaptureOptions: _captureOptions,
          );
        }
        _error = null;
      } catch (e) {
        _error = 'Микрофон недоступен: $e';
      }
    }
    notifyListeners();
  }

  /// Включить или выключить обработку голоса.
  ///
  /// Пересоздаём дорожку: LiveKit применяет настройки захвата только при
  /// публикации, на лету их не поменять.
  Future<void> toggleAudioProcessing() async {
    _audioProcessing = !_audioProcessing;

    final room = _room;
    if (room != null && _micEnabled) {
      try {
        await room.localParticipant?.setMicrophoneEnabled(false);
        await room.localParticipant?.setMicrophoneEnabled(
          true,
          audioCaptureOptions: _captureOptions,
        );
      } catch (e) {
        _error = 'Не удалось применить настройки: $e';
      }
    }

    notifyListeners();
  }

  Future<void> toggleMicrophone() async {
    final room = _room;
    if (room == null) return;

    final next = !_micEnabled;
    await room.localParticipant?.setMicrophoneEnabled(
      next,
      audioCaptureOptions: _captureOptions,
    );
    _micEnabled = next;

    // Включение микрофона автоматически снимает глушение.
    if (next && _deafened) {
      _deafened = false;
      await _setRemoteAudioEnabled(true);
    }

    await _pushState();
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final room = _room;
    if (room == null || !_canVideo) return;

    final next = !_cameraEnabled;
    try {
      await room.localParticipant?.setCameraEnabled(next);
      _cameraEnabled = next;
      _error = null;
    } catch (e) {
      _error = 'Камера недоступна: $e';
    }
    notifyListeners();
  }

  Future<void> toggleScreenShare({String? sourceId}) async {
    final room = _room;
    if (room == null || !_canScreenShare) return;

    final next = !_screenSharing;
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

    // На Windows/Linux/macOS native getDisplayMedia не выбирает источник
    // сам: без sourceId он возвращает "source not found!". На Android
    // источник выбирает MediaProjection, там sourceId не нужен.
    if (next &&
        lkPlatformIsDesktop() &&
        (sourceId == null || sourceId.isEmpty)) {
      _error = 'Выберите экран или окно для показа';
      _screenSharing = false;
      notifyListeners();
      return;
    }

    // Сервис поднимаем до запроса разрешения: Android 14+ проверяет его
    // в момент getMediaProjection().
    if (android && next) {
      await _screenShareChannel.invokeMethod<void>('start');
    }

    try {
      final options = sourceId == null || sourceId.isEmpty
          ? null
          : ScreenShareCaptureOptions(sourceId: sourceId, maxFrameRate: 15);
      await room.localParticipant?.setScreenShareEnabled(
        next,
        screenShareCaptureOptions: options,
      );
      _screenSharing = next;
      _error = null;
    } catch (e) {
      _screenSharing = false;
      _error = 'Демонстрация экрана недоступна: $e';
    } finally {
      if (android && !_screenSharing) {
        await _screenShareChannel.invokeMethod<void>('stop');
      }
    }
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
      await api.voiceState(id, selfMute: !_micEnabled, selfDeaf: _deafened);
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
    _cameraEnabled = false;
    _screenSharing = false;
    _canVideo = false;
    _canScreenShare = false;
    _error = null;
    _micLevel = 0;

    if (room != null) {
      await room.disconnect();
      await room.dispose();
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await _screenShareChannel.invokeMethod<void>('stop');
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
