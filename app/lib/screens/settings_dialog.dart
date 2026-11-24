import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../core/version.dart';
import '../state/app_controller.dart';
import '../theme.dart';

enum SettingsSection { voice, account, about }

Future<void> openSettings(
  BuildContext context,
  AppController controller, {
  SettingsSection section = SettingsSection.voice,
}) async {
  final wide = MediaQuery.sizeOf(context).width >= 850;
  if (wide) {
    await showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(
        controller: controller,
        initialSection: section,
      ),
    );
    return;
  }

  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsDialog(
        controller: controller,
        initialSection: section,
        fullScreen: true,
      ),
    ),
  );
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.controller,
    this.initialSection = SettingsSection.voice,
    this.fullScreen = false,
  });

  final AppController controller;
  final SettingsSection initialSection;
  final bool fullScreen;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late SettingsSection _section = widget.initialSection;

  @override
  Widget build(BuildContext context) {
    final content = switch (_section) {
      SettingsSection.voice => _VoiceSettings(controller: widget.controller),
      SettingsSection.account => _AccountSettings(controller: widget.controller),
      SettingsSection.about => _AboutSettings(controller: widget.controller),
    };

    if (widget.fullScreen) {
      return Scaffold(
        backgroundColor: kBackground,
        appBar: AppBar(
          backgroundColor: kSidebar,
          title: const Text('Настройки'),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<SettingsSection>(
                  segments: const [
                    ButtonSegment(
                      value: SettingsSection.voice,
                      icon: Icon(Icons.mic, size: 18),
                      label: Text('Голос и видео'),
                    ),
                    ButtonSegment(
                      value: SettingsSection.account,
                      icon: Icon(Icons.person_outline, size: 18),
                      label: Text('Аккаунт'),
                    ),
                    ButtonSegment(
                      value: SettingsSection.about,
                      icon: Icon(Icons.info_outline, size: 18),
                      label: Text('О приложении'),
                    ),
                  ],
                  selected: {_section},
                  onSelectionChanged: (value) {
                    setState(() => _section = value.first);
                  },
                ),
              ),
            ),
            const Divider(height: 1, color: kRail),
            Expanded(child: content),
          ],
        ),
      );
    }

    return Dialog(
      backgroundColor: kSidebar,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 650),
        child: Row(
          children: [
            SizedBox(
              width: 220,
              child: _SettingsSidebar(
                controller: widget.controller,
                section: _section,
                onSelect: (value) => setState(() => _section = value),
              ),
            ),
            const VerticalDivider(width: 1, color: kRail),
            Expanded(
              child: Column(
                children: [
                  _SettingsHeader(onClose: () => Navigator.of(context).pop()),
                  const Divider(height: 1, color: kRail),
                  Expanded(child: content),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSidebar extends StatelessWidget {
  const _SettingsSidebar({
    required this.controller,
    required this.section,
    required this.onSelect,
  });

  final AppController controller;
  final SettingsSection section;
  final ValueChanged<SettingsSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final user = controller.user;
    return ColoredBox(
      color: kRail,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: kAccent,
                  child: Text(
                    user?.name.substring(0, 1).toUpperCase() ?? '?',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user?.name ?? 'Пользователь',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        user == null ? '' : '@${user.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: kTextMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: kSidebar),
          const SizedBox(height: 8),
          _SettingsNavTile(
            icon: Icons.mic,
            label: 'Голос и видео',
            selected: section == SettingsSection.voice,
            onTap: () => onSelect(SettingsSection.voice),
          ),
          _SettingsNavTile(
            icon: Icons.person_outline,
            label: 'Аккаунт',
            selected: section == SettingsSection.account,
            onTap: () => onSelect(SettingsSection.account),
          ),
          _SettingsNavTile(
            icon: Icons.info_outline,
            label: 'О приложении',
            selected: section == SettingsSection.about,
            onTap: () => onSelect(SettingsSection.about),
          ),
        ],
      ),
    );
  }
}

class _SettingsNavTile extends StatelessWidget {
  const _SettingsNavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          dense: true,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          selected: selected,
          selectedTileColor: kSidebar,
          leading: Icon(icon, size: 18),
          title: Text(label, style: const TextStyle(fontSize: 13)),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: 24, right: 12),
        child: Row(
          children: [
            const Text(
              'Настройки',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Закрыть',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceSettings extends StatefulWidget {
  const _VoiceSettings({required this.controller});

  final AppController controller;

  @override
  State<_VoiceSettings> createState() => _VoiceSettingsState();
}

class _VoiceSettingsState extends State<_VoiceSettings> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.voice.loadAudioDevices());
  }

  @override
  Widget build(BuildContext context) {
    final voice = widget.controller.voice;
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
          children: [
            const Text(
              'Голос и видео',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            _SettingsCard(
              title: 'Микрофон',
              children: [
                const Text(
                  'Уровень микрофона',
                  style: TextStyle(fontSize: 12, color: kTextMuted),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: voice.micLevel.clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor: kRail,
                    color: voice.micLevel > 0.02 ? kOnline : kTextMuted,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Говорите обычным голосом — полоса покажет уровень.',
                  style: TextStyle(fontSize: 11, color: kTextMuted),
                ),
                const SizedBox(height: 14),
                _DeviceDropdown(
                  label: 'Устройство ввода',
                  devices: voice.audioInputs,
                  selectedId: voice.selectedMicId,
                  onChanged: (device) => unawaited(
                    voice.selectMicrophone(device),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: voice.loadAudioDevices,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Обновить список устройств'),
                  ),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Шумоподавление'),
                  subtitle: const Text(
                    'Убирает фон. Если голос стал тише — попробуйте выключить.',
                    style: TextStyle(fontSize: 11, color: kTextMuted),
                  ),
                  value: voice.noiseSuppression,
                  onChanged: (value) => unawaited(
                    voice.setNoiseSuppression(value),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Автоусиление (AGC)'),
                  subtitle: const Text(
                    'Выравнивает громкость. Для тихого микрофона лучше оставить включённым.',
                    style: TextStyle(fontSize: 11, color: kTextMuted),
                  ),
                  value: voice.autoGainControl,
                  onChanged: (value) => unawaited(
                    voice.setAutoGainControl(value),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Эхо-подавление'),
                  subtitle: const Text(
                    'Убирает эхо от динамиков.',
                    style: TextStyle(fontSize: 11, color: kTextMuted),
                  ),
                  value: voice.echoCancellation,
                  onChanged: (value) => unawaited(
                    voice.setEchoCancellation(value),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => _MicTestDialog(controller: widget.controller),
                    ),
                    icon: const Icon(Icons.mic, size: 18),
                    label: const Text('Проверить микрофон'),
                  ),
                ),
                if (voice.error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    voice.error!,
                    style: const TextStyle(color: kDanger, fontSize: 12),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              title: 'Динамики',
              children: [
                if (voice.audioOutputs.isEmpty)
                  const Text(
                    'Системное устройство вывода. Выбор доступен, когда система отдаёт список устройств.',
                    style: TextStyle(fontSize: 12, color: kTextMuted),
                  )
                else
                  _DeviceDropdown(
                    label: 'Устройство вывода',
                    devices: voice.audioOutputs,
                    selectedId: voice.selectedOutputId,
                    onChanged: (device) => unawaited(
                      voice.selectAudioOutput(device),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Громкость', style: TextStyle(fontSize: 13)),
                    const Spacer(),
                    Text(
                      '${(voice.outputVolume * 100).round()}%',
                      style: const TextStyle(fontSize: 12, color: kTextMuted),
                    ),
                  ],
                ),
                Slider(
                  value: voice.outputVolume.clamp(0.0, 1.0),
                  onChanged: (value) => unawaited(voice.setOutputVolume(value)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _CameraSettings(controller: widget.controller),
          ],
        );
      },
    );
  }
}

class _DeviceDropdown extends StatelessWidget {
  const _DeviceDropdown({
    required this.label,
    required this.devices,
    required this.selectedId,
    required this.onChanged,
  });

  final String label;
  final List<MediaDevice> devices;
  final String? selectedId;
  final ValueChanged<MediaDevice> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = devices.any((device) => device.deviceId == selectedId)
        ? selectedId
        : null;

    return DropdownButtonFormField<String>(
      key: ValueKey(selectedId ?? 'none'),
      initialValue: selected,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final device in devices)
          DropdownMenuItem(
            value: device.deviceId,
            child: Text(
              device.label.isEmpty ? 'Устройство ${device.deviceId}' : device.label,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (id) {
        if (id == null) return;
        for (final device in devices) {
          if (device.deviceId == id) {
            onChanged(device);
            break;
          }
        }
      },
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kSidebar,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kRail),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _CameraSettings extends StatefulWidget {
  const _CameraSettings({required this.controller});

  final AppController controller;

  @override
  State<_CameraSettings> createState() => _CameraSettingsState();
}

class _CameraSettingsState extends State<_CameraSettings> {
  LocalVideoTrack? _preview;
  bool _ownsPreview = false;
  bool _previewEnabled = false;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    await widget.controller.voice.loadVideoDevices();
    await _restartPreview();
  }

  Future<void> _restartPreview() async {
    final voice = widget.controller.voice;
    _releasePreview();

    if (voice.connected) {
      if (!mounted) return;
      setState(() {
        _preview = voice.localCameraTrack;
        _loading = false;
      });
      return;
    }

    if (!_previewEnabled) {
      if (!mounted) return;
      setState(() {
        _preview = null;
        _loading = false;
        _error = null;
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final track = await LocalVideoTrack.createCameraTrack(voice.cameraOptions);
      if (!mounted) {
        unawaited(track.dispose());
        return;
      }
      setState(() {
        _preview = track;
        _ownsPreview = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Камера недоступна: $e';
        _loading = false;
      });
    }
  }

  void _releasePreview() {
    if (_ownsPreview) {
      unawaited(_preview?.dispose());
    }
    _preview = null;
    _ownsPreview = false;
  }

  @override
  void dispose() {
    _releasePreview();
    super.dispose();
  }

  Future<void> _apply(Future<void> Function() action) async {
    await action();
    if (mounted) await _restartPreview();
  }

  Future<void> _togglePreview() async {
    setState(() => _previewEnabled = !_previewEnabled);
    await _restartPreview();
  }

  @override
  Widget build(BuildContext context) {
    final voice = widget.controller.voice;
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final devices = voice.videoInputs;
        return _SettingsCard(
          title: 'Камера',
          children: [
            Text(
              voice.connected
                  ? 'Настройки применятся к текущему звонку.'
                  : 'Превью включит камеру только на время настроек. В звонке настройки применятся при включении камеры.',
              style: const TextStyle(fontSize: 12, color: kTextMuted),
            ),
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: ColoredBox(
                  color: Colors.black,
                  child: _preview != null
                      ? VideoTrackRenderer(
                          _preview!,
                          fit: VideoViewFit.cover,
                          mirrorMode: voice.mirrorPreview
                              ? VideoViewMirrorMode.mirror
                              : VideoViewMirrorMode.off,
                        )
                      : Center(
                          child: _loading
                              ? const CircularProgressIndicator()
                              : Text(
                                  _error ??
                                      (voice.connected
                                          ? 'Камера выключена в звонке'
                                          : 'Превью выключено'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: kTextMuted,
                                    fontSize: 12,
                                  ),
                                ),
                        ),
                ),
              ),
            ),
            if (!voice.connected)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _togglePreview,
                  icon: Icon(
                    _previewEnabled ? Icons.videocam_off : Icons.videocam,
                    size: 18,
                  ),
                  label: Text(
                    _previewEnabled ? 'Остановить превью' : 'Включить превью',
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (devices.isEmpty)
              const Text(
                'Камеры не найдены.',
                style: TextStyle(fontSize: 12, color: kTextMuted),
              )
            else
              _DeviceDropdown(
                label: 'Устройство',
                devices: devices,
                selectedId: voice.selectedCameraId,
                onChanged: (device) => unawaited(
                  _apply(() => voice.selectCamera(device)),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => unawaited(voice.loadVideoDevices()),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Обновить список камер'),
              ),
            ),
            const SizedBox(height: 4),
            const Text('Качество', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: '720p', label: Text('720p')),
                ButtonSegment(value: '1080p', label: Text('1080p')),
              ],
              selected: {voice.cameraResolution},
              onSelectionChanged: (value) => unawaited(
                _apply(() => voice.setCameraResolution(value.first)),
              ),
            ),
            const SizedBox(height: 10),
            const Text('Частота кадров', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 15, label: Text('15 fps')),
                ButtonSegment(value: 30, label: Text('30 fps')),
              ],
              selected: {voice.cameraFps},
              onSelectionChanged: (value) => unawaited(
                _apply(() => voice.setCameraFps(value.first)),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Зеркало превью'),
              subtitle: const Text(
                'Только для себя; другим уходит обычное изображение.',
                style: TextStyle(fontSize: 11, color: kTextMuted),
              ),
              value: voice.mirrorPreview,
              onChanged: (value) =>
                  unawaited(voice.setMirrorPreview(value)),
            ),
          ],
        );
      },
    );
  }
}

class _AccountSettings extends StatefulWidget {
  const _AccountSettings({required this.controller});

  final AppController controller;

  @override
  State<_AccountSettings> createState() => _AccountSettingsState();
}

class _AccountSettingsState extends State<_AccountSettings> {
  final _currentPassword = TextEditingController();
  final _newPassword = TextEditingController();
  final _repeatPassword = TextEditingController();

  List<UserSession> _sessions = const [];
  bool _loadingSessions = true;
  String? _sessionsError;
  String? _revokingID;
  bool _changingPassword = false;
  String? _passwordError;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSessions());
  }

  @override
  void dispose() {
    _currentPassword.dispose();
    _newPassword.dispose();
    _repeatPassword.dispose();
    super.dispose();
  }

  Future<void> _loadSessions() async {
    final generation = ++_generation;
    setState(() {
      _loadingSessions = true;
      _sessionsError = null;
    });
    try {
      final items = await widget.controller.sessions();
      if (!mounted || generation != _generation) return;
      setState(() {
        _sessions = items;
        _loadingSessions = false;
      });
    } on ApiException catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _sessionsError = error.message;
        _loadingSessions = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _sessionsError = 'Не удалось загрузить сессии';
        _loadingSessions = false;
      });
    }
  }

  Future<void> _revoke(UserSession session) async {
    setState(() => _revokingID = session.id);
    try {
      await widget.controller.revokeSession(session.id);
      if (!mounted) return;
      await _loadSessions();
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Не удалось завершить сессию')));
    } finally {
      if (mounted) setState(() => _revokingID = null);
    }
  }

  Future<void> _changePassword() async {
    final current = _currentPassword.text;
    final next = _newPassword.text;
    final repeat = _repeatPassword.text;

    if (current.isEmpty) {
      setState(() => _passwordError = 'Введите текущий пароль');
      return;
    }
    if (next.length < 10) {
      setState(() => _passwordError = 'Новый пароль — не короче 10 символов');
      return;
    }
    if (next != repeat) {
      setState(() => _passwordError = 'Пароли не совпадают');
      return;
    }

    setState(() {
      _changingPassword = true;
      _passwordError = null;
    });
    try {
      await widget.controller.changePassword(
        currentPassword: current,
        newPassword: next,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Пароль изменён'),
          content: const Text(
            'Все сессии завершены. Войдите с новым паролем.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Войти заново'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _passwordError = error.message;
        _changingPassword = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _passwordError = 'Не удалось сменить пароль';
        _changingPassword = false;
      });
    }
  }

  Future<void> _logoutAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти на всех устройствах?'),
        content: const Text(
          'Все сессии, включая текущую, будут завершены. Придётся войти заново.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Выйти везде'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.controller.logoutAll();
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.controller.user;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
      children: [
        const Text(
          'Аккаунт',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: 'Профиль',
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: kAccent,
                  child: Text(
                    user?.name.substring(0, 1).toUpperCase() ?? '?',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user?.name ?? 'Пользователь',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        user == null ? '' : '@${user.username}',
                        style: const TextStyle(color: kTextMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _InfoRow(label: 'ID', value: user?.id ?? '—'),
          ],
        ),
        const SizedBox(height: 16),
        _SettingsCard(
          title: 'Смена пароля',
          children: [
            const Text(
              'После смены все сессии, включая текущую, завершатся — войти нужно будет заново.',
              style: TextStyle(fontSize: 12, color: kTextMuted),
            ),
            const SizedBox(height: 12),
            _PasswordField(
              controller: _currentPassword,
              label: 'Текущий пароль',
            ),
            const SizedBox(height: 10),
            _PasswordField(
              controller: _newPassword,
              label: 'Новый пароль (не короче 10 символов)',
            ),
            const SizedBox(height: 10),
            _PasswordField(
              controller: _repeatPassword,
              label: 'Новый пароль ещё раз',
            ),
            if (_passwordError != null) ...[
              const SizedBox(height: 10),
              Text(
                _passwordError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _changingPassword ? null : _changePassword,
              child: _changingPassword
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Сменить пароль'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _SettingsCard(
          title: 'Активные сессии',
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Устройства, с которых выполнен вход.',
                    style: TextStyle(fontSize: 12, color: kTextMuted),
                  ),
                ),
                IconButton(
                  onPressed: _loadingSessions ? null : _loadSessions,
                  tooltip: 'Обновить',
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (_loadingSessions)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_sessionsError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _sessionsError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _loadSessions,
                      child: const Text('Повторить'),
                    ),
                  ],
                ),
              )
            else if (_sessions.isEmpty)
              const Text(
                'Активных сессий нет.',
                style: TextStyle(fontSize: 12, color: kTextMuted),
              )
            else
              ..._sessions.map(
                (session) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices, size: 20),
                  title: Text(
                    _deviceName(session.userAgent),
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    [
                      if (session.ip.isNotEmpty) session.ip,
                      'активность ${_relativeTime(session.lastSeenAt)}',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: session.current
                      ? const Chip(
                          label: Text('Это устройство'),
                          visualDensity: VisualDensity.compact,
                        )
                      : TextButton(
                          onPressed: _revokingID == session.id
                              ? null
                              : () => _revoke(session),
                          child: _revokingID == session.id
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Завершить'),
                        ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _SettingsCard(
          title: 'Безопасность',
          children: [
            const Text(
              'Двухфакторная аутентификация появится позже.',
              style: TextStyle(fontSize: 12, color: kTextMuted),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _logoutAll,
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Выйти на всех устройствах'),
            ),
          ],
        ),
      ],
    );
  }
}

class _PasswordField extends StatelessWidget {
  const _PasswordField({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: true,
      decoration: InputDecoration(labelText: label, isDense: true),
    );
  }
}

String _deviceName(String userAgent) {
  final ua = userAgent.toLowerCase();
  if (ua.contains('android')) return 'Android';
  if (ua.contains('iphone') || ua.contains('ipad')) return 'iOS';
  if (ua.contains('windows')) return 'Windows';
  if (ua.contains('mac os') || ua.contains('macintosh')) return 'macOS';
  if (ua.contains('linux')) return 'Linux';
  return 'Неизвестное устройство';
}

String _relativeTime(DateTime? time) {
  if (time == null) return 'неизвестно';
  final diff = DateTime.now().difference(time.toLocal());
  if (diff.inMinutes < 1) return 'только что';
  if (diff.inMinutes < 60) return '${diff.inMinutes} мин назад';
  if (diff.inHours < 24) return '${diff.inHours} ч назад';
  if (diff.inDays < 7) return '${diff.inDays} дн назад';
  final local = time.toLocal();
  return '${local.day.toString().padLeft(2, '0')}.'
      '${local.month.toString().padLeft(2, '0')}.${local.year}';
}

class _MicTestDialog extends StatelessWidget {
  const _MicTestDialog({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Проверка микрофона'),
      content: ListenableBuilder(
        listenable: controller.voice,
        builder: (context, _) {
          final level = controller.voice.micLevel.clamp(0.0, 1.0);
          return SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Говорите обычным голосом и смотрите на полосу.'),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: level,
                    minHeight: 12,
                    backgroundColor: kRail,
                    color: level > 0.02 ? kOnline : kTextMuted,
                  ),
                ),
              ],
            ),
          );
        },
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Готово'),
        ),
      ],
    );
  }
}

class _AboutSettings extends StatelessWidget {
  const _AboutSettings({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
      children: [
        const Text(
          'О приложении',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          title: 'Voxnica',
          children: [
            const Text('Текстовые каналы, голос и видео.'),
            const SizedBox(height: 12),
            _InfoRow(label: 'Версия', value: 'v$kAppVersion'),
            _InfoRow(label: 'Сервер', value: controller.api.baseUrl),
          ],
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () async {
            await Clipboard.setData(
              ClipboardData(
                text:
                    'Voxnica v$kAppVersion\nServer: ${controller.api.baseUrl}\nUser: ${controller.user?.username ?? '—'}',
              ),
            );
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Диагностика скопирована')),
            );
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Скопировать диагностику'),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: kTextMuted)),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
