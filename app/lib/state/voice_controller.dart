import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:livekit_client/livekit_client.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import 'app_settings.dart';

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
  VoiceController(this.api, this.settings);

  /// Канал к MainActivity: foreground service, без которого Android 14+
  /// не разрешает захват экрана.
  static const MethodChannel _screenShareChannel = MethodChannel(
    'voxnica/screen_share',
  );

  final ApiClient api;
  final AppSettings settings;

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

  /// Уровень своего микрофона 0..1 — для индикатора «вас слышно».
  double _micLevel = 0;

  List<MediaDevice> _audioInputs = const [];
  List<MediaDevice> _audioOutputs = const [];
  String? _selectedMicId;
  String? _selectedOutputId;

  /// Настройки захвата звука.
  ///
  /// Явно, а не «как в SDK по умолчанию»: по умолчанию включены
  /// voiceIsolation и typingNoiseDetection, которые на Android и в
  /// эмуляторе дают металлический призвук; highPassFilter наоборот
  /// полезен — убирает гул стола и вентилятора.
  AudioCaptureOptions get _captureOptions => AudioCaptureOptions(
    deviceId: _selectedMicId ?? settings.micDeviceId,
    echoCancellation: settings.echoCancellation,
    noiseSuppression: settings.noiseSuppression,
    autoGainControl: settings.autoGainControl,
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
  bool get noiseSuppression => settings.noiseSuppression;
  bool get autoGainControl => settings.autoGainControl;
  bool get echoCancellation => settings.echoCancellation;
  double get outputVolume => settings.outputVolume;
  double get micLevel => _micLevel;
  List<MediaDevice> get audioInputs => _audioInputs;
  List<MediaDevice> get audioOutputs => _audioOutputs;
  String? get selectedMicId => _selectedMicId;
  String? get selectedOutputId => _selectedOutputId;

  /// Трек виден, только если он не замьючен.
  ///
  /// `setCameraEnabled(false)` не удаляет публикацию, а мьютит её.
  /// Без этой проверки в сетке остаётся последний кадр выключенной камеры.
  bool _isLive(TrackPublication publication) {
    final track = publication.track;
    return track != null && !publication.muted && !track.muted;
  }

  /// Локальная камера — для превью в сетке.
  LocalVideoTrack? get localCameraTrack {
    final participant = _room?.localParticipant;
    if (participant == null || !_cameraEnabled) return null;

    for (final publication in participant.videoTrackPublications) {
      if (publication.source == TrackSource.camera &&
          _isLive(publication) &&
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
        if (publication.source == TrackSource.camera &&
            track != null &&
            _isLive(publication)) {
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
        if (publication.source == TrackSource.camera &&
            track != null &&
            _isLive(publication)) {
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

  /// Демонстрации экрана: своя и чужие. Показываем все одновременно:
  /// у каждого участника может быть свой показ.
  List<VideoTile> get screenShareTiles {
    final out = <VideoTile>[];

    final local = _room?.localParticipant;
    if (local != null) {
      for (final publication in local.videoTrackPublications) {
        if (publication.source == TrackSource.screenShareVideo &&
            _isLive(publication) &&
            publication.track is VideoTrack) {
          out.add(
            VideoTile(
              track: publication.track as VideoTrack,
              name: 'Вы',
              isLocal: true,
            ),
          );
        }
      }
    }

    final participants = _room?.remoteParticipants.values;
    if (participants == null) return out;

    for (final participant in participants) {
      for (final publication in participant.videoTrackPublications) {
        final track = publication.track;
        if (publication.source == TrackSource.screenShareVideo &&
            track is VideoTrack &&
            _isLive(publication)) {
          out.add(
            VideoTile(
              track: track as VideoTrack,
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
          defaultAudioOutputOptions: AudioOutputOptions(
            deviceId: _selectedOutputId ?? settings.outputDeviceId,
          ),
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
          if (event.track is RemoteAudioTrack) {
            if (_deafened) {
              await event.track.stop();
            } else {
              await _applyTrackVolume(event.track as RemoteAudioTrack);
            }
          }
          notifyListeners();
        })
        ..on<TrackUnsubscribedEvent>((_) => notifyListeners())
        // Выключение чужой камеры/экрана — это mute, а не unsubscribe.
        ..on<TrackMutedEvent>((_) => notifyListeners())
        ..on<TrackUnmutedEvent>((_) => notifyListeners());

      if (info.canSpeak) {
        await room.localParticipant?.setMicrophoneEnabled(
          true,
          audioCaptureOptions: _captureOptions,
        );
        _micEnabled = true;
        await loadAudioDevices();
      }

      await _applyOutputVolume();
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

  /// Список устройств ввода и вывода. Заполняется при старте и входе в канал.
  Future<void> loadAudioDevices() async {
    try {
      _audioInputs = await Hardware.instance.audioInputs();
    } catch (_) {
      _audioInputs = const [];
    }
    try {
      _audioOutputs = await Hardware.instance.audioOutputs();
    } catch (_) {
      _audioOutputs = const [];
    }

    final savedMic = settings.micDeviceId;
    if (savedMic != null &&
        _audioInputs.any((device) => device.deviceId == savedMic)) {
      _selectedMicId = savedMic;
    } else if (_selectedMicId == null ||
        !_audioInputs.any((device) => device.deviceId == _selectedMicId)) {
      _selectedMicId = Hardware.instance.selectedAudioInput?.deviceId;
    }

    final savedOutput = settings.outputDeviceId;
    if (savedOutput != null &&
        _audioOutputs.any((device) => device.deviceId == savedOutput)) {
      _selectedOutputId = savedOutput;
    } else if (_selectedOutputId == null ||
        !_audioOutputs.any((device) => device.deviceId == _selectedOutputId)) {
      _selectedOutputId = Hardware.instance.selectedAudioOutput?.deviceId;
    }

    notifyListeners();
  }

  /// Переключить микрофон (гарнитура вместо встроенного).
  Future<void> selectMicrophone(MediaDevice device) async {
    _selectedMicId = device.deviceId;
    settings.micDeviceId = device.deviceId;
    await settings.save();

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

  /// Переключить устройство вывода.
  Future<void> selectAudioOutput(MediaDevice device) async {
    _selectedOutputId = device.deviceId;
    settings.outputDeviceId = device.deviceId;
    await settings.save();

    final room = _room;
    if (room != null) {
      try {
        await room.setAudioOutputDevice(device);
        _error = null;
      } catch (e) {
        _error = 'Устройство вывода недоступно: $e';
      }
    }
    notifyListeners();
  }

  Future<void> setNoiseSuppression(bool value) async {
    if (settings.noiseSuppression == value) return;
    settings.noiseSuppression = value;
    await settings.save();
    await _restartMicrophone();
    notifyListeners();
  }

  Future<void> setAutoGainControl(bool value) async {
    if (settings.autoGainControl == value) return;
    settings.autoGainControl = value;
    await settings.save();
    await _restartMicrophone();
    notifyListeners();
  }

  Future<void> setEchoCancellation(bool value) async {
    if (settings.echoCancellation == value) return;
    settings.echoCancellation = value;
    await settings.save();
    await _restartMicrophone();
    notifyListeners();
  }

  Future<void> setOutputVolume(double value) async {
    final next = value.clamp(0.0, 1.0).toDouble();
    if ((settings.outputVolume - next).abs() < 0.001) return;
    settings.outputVolume = next;
    await settings.save();
    await _applyOutputVolume();
    notifyListeners();
  }

  /// Пересоздаём дорожку: LiveKit применяет настройки захвата только при
  /// публикации, на лету их не поменять.
  Future<void> _restartMicrophone() async {
    final room = _room;
    if (room == null || !_micEnabled) return;

    try {
      await room.localParticipant?.setMicrophoneEnabled(false);
      await room.localParticipant?.setMicrophoneEnabled(
        true,
        audioCaptureOptions: _captureOptions,
      );
      _error = null;
    } catch (e) {
      _error = 'Не удалось применить настройки микрофона: $e';
    }
  }

  Future<void> _applyOutputVolume() async {
    final room = _room;
    if (room == null) return;

    for (final participant in room.remoteParticipants.values) {
      for (final publication in participant.audioTrackPublications) {
        final track = publication.track;
        if (track is RemoteAudioTrack) {
          await _applyTrackVolume(track);
        }
      }
    }
  }

  Future<void> _applyTrackVolume(RemoteAudioTrack track) async {
    try {
      await Helper.setVolume(settings.outputVolume, track.mediaStreamTrack);
    } catch (_) {
      // Громкость — не критично для соединения.
    }
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
            await _applyTrackVolume(track);
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
