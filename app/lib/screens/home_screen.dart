import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../api/models.dart';
import '../core/version.dart';
import '../gateway/gateway_client.dart';
import '../state/app_controller.dart';
import '../state/voice_controller.dart';
import '../theme.dart';
import '../widgets/invite_dialog.dart';
import 'channel_screen.dart';
import 'friends_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 850;

    Future<void> openChannel(Channel channel) async {
      await controller.selectChannel(channel);
      if (wide || !context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChannelScreen(controller: controller),
        ),
      );
    }

    Future<void> openDm(DmChannel dm) async {
      // Диалог мог быть уже выбран (например, сразу после startDm) —
      // второй раз ленту не грузим.
      if (controller.dm?.id != dm.id) await controller.selectDm(dm);
      if (wide || !context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChannelScreen(controller: controller),
        ),
      );
    }

    final Widget sidebar = controller.dmHome
        ? _DmHomeSidebar(controller: controller, onOpenDm: openDm)
        : _ChannelSidebar(
            controller: controller,
            onOpenChannel: openChannel,
            onOpenDm: openDm,
          );

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _GuildRail(controller: controller),
            if (wide) ...[
              SizedBox(width: 250, child: sidebar),
              const VerticalDivider(width: 1, color: Color(0xFF1E1F22)),
              Expanded(child: ChannelPane(controller: controller)),
            ] else
              Expanded(child: sidebar),
          ],
        ),
      ),
    );
  }
}

class _GuildRail extends StatelessWidget {
  const _GuildRail({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      color: kRail,
      child: Column(
        children: [
          const SizedBox(height: 12),
          IconButton(
            tooltip: 'Личные сообщения',
            onPressed: controller.openDmHome,
            icon: const Icon(Icons.forum_outlined),
            color: controller.dmHome ? kAccent : kOnline,
          ),
          IconButton(
            tooltip: 'Друзья',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => FriendsScreen(controller: controller),
              ),
            ),
            icon: const Icon(Icons.people_alt_outlined),
            color: kOnline,
          ),
          Expanded(
            child: ListView.builder(
              itemCount: controller.guilds.length,
              itemBuilder: (context, index) {
                final guild = controller.guilds[index];
                final selected = guild.id == controller.guild?.id;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Tooltip(
                    message: guild.name,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => controller.selectGuild(guild),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: 48,
                        height: 48,
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: selected ? kAccent : kSidebar,
                          borderRadius: BorderRadius.circular(
                            selected ? 16 : 24,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          guild.initials,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: 'Присоединиться по коду',
            onPressed: () => _joinByCode(context),
            icon: const Icon(Icons.group_add_outlined),
            color: kOnline,
          ),
          IconButton(
            tooltip: 'Создать сервер',
            onPressed: () => _createGuild(context),
            icon: const Icon(Icons.add_circle_outline),
            color: kOnline,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _joinByCode(BuildContext context) async {
    final code = await _prompt(
      context,
      'Присоединиться к серверу',
      'Код приглашения',
    );
    if (code == null || code.trim().isEmpty) return;

    final ok = await controller.joinByInvite(code);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(controller.error ?? 'Не удалось присоединиться'),
        ),
      );
    }
  }

  Future<void> _createGuild(BuildContext context) async {
    final name = await _prompt(context, 'Новый сервер', 'Название сервера');
    if (name == null || name.trim().isEmpty) return;

    final ok = await controller.createGuild(name);
    if (!context.mounted) return;
    if (!ok && controller.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(controller.error!)));
    }
  }
}

class _ChannelSidebar extends StatelessWidget {
  const _ChannelSidebar({
    required this.controller,
    required this.onOpenChannel,
    required this.onOpenDm,
  });

  final AppController controller;
  final Future<void> Function(Channel) onOpenChannel;
  final Future<void> Function(DmChannel) onOpenDm;

  @override
  Widget build(BuildContext context) {
    final guild = controller.guild;

    return Container(
      color: kSidebar,
      child: Column(
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF1E1F22))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    guild?.name ?? 'Серверы',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (guild != null) ...[
                  IconButton(
                    tooltip: 'Пригласить в сервер',
                    onPressed: () => _invite(context),
                    icon: const Icon(Icons.person_add_alt_1, size: 20),
                  ),
                  IconButton(
                    tooltip: 'Создать канал',
                    onPressed: () => _createChannel(context),
                    icon: const Icon(Icons.add, size: 20),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                Row(
                  children: [
                    const Expanded(child: _GroupLabel('ЛИЧНЫЕ СООБЩЕНИЯ')),
                    IconButton(
                      tooltip: 'Новый диалог',
                      onPressed: () => _createDm(context),
                      icon: const Icon(Icons.person_add_alt, size: 18),
                    ),
                  ],
                ),
                if (controller.dms.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Text(
                      'Нажмите +, чтобы написать участнику сервера',
                      style: TextStyle(fontSize: 11, color: kTextMuted),
                    ),
                  )
                else
                  ...controller.dms.map(
                    (dm) => _DmTile(
                      dm: dm,
                      selfId: controller.user?.id ?? '',
                      unread: controller.dmUnread(dm.id),
                      selected: controller.dm?.id == dm.id,
                      onTap: () => onOpenDm(dm),
                    ),
                  ),
                if (guild != null) ...[
                  if (controller.textChannels.isNotEmpty)
                    const _GroupLabel('ТЕКСТОВЫЕ КАНАЛЫ'),
                  ...controller.textChannels.map(
                    (channel) => _ChannelTile(
                      channel: channel,
                      selected:
                          controller.dm == null &&
                          controller.channel?.id == channel.id,
                      onTap: () => onOpenChannel(channel),
                    ),
                  ),
                  if (controller.voiceChannels.isNotEmpty)
                    const _GroupLabel('ГОЛОСОВЫЕ КАНАЛЫ'),
                  ...controller.voiceChannels.map(
                    (channel) => _ChannelTile(
                      channel: channel,
                      selected:
                          controller.dm == null &&
                          controller.channel?.id == channel.id,
                      onTap: () => onOpenChannel(channel),
                    ),
                  ),
                ] else
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Создайте сервер кнопкой «+» слева или присоединитесь '
                      'по коду приглашения',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kTextMuted),
                    ),
                  ),
              ],
            ),
          ),
          _UserFooter(controller: controller),
        ],
      ),
    );
  }

  Future<void> _invite(BuildContext context) async {
    final code = await controller.createInvite();
    if (!context.mounted) return;

    if (code == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(controller.error ?? 'Не удалось создать приглашение'),
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => InviteCodeDialog(code: code),
    );
  }

  Future<void> _createChannel(BuildContext context) async {
    final result = await showDialog<({String name, String type})>(
      context: context,
      builder: (context) => const _CreateChannelDialog(),
    );
    if (result == null) return;

    final ok = await controller.createChannel(result.name, result.type);
    if (!context.mounted) return;
    if (!ok && controller.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(controller.error!)));
    }
  }

  Future<void> _createDm(BuildContext context) async {
    final member = await showDialog<GuildMember>(
      context: context,
      builder: (context) => _NewDmDialog(
        members: controller.members,
        selfId: controller.user?.id ?? '',
      ),
    );
    if (member == null) return;

    final ok = await controller.startDm(member.userId);
    if (!context.mounted) return;
    if (!ok && controller.error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(controller.error!)));
    }
  }
}

/// Сайдбар «домашнего» раздела личных сообщений — как в Discord:
/// поиск сверху, «Друзья» с бейджем, список диалогов с аватарами.
class _DmHomeSidebar extends StatelessWidget {
  const _DmHomeSidebar({required this.controller, required this.onOpenDm});

  final AppController controller;
  final Future<void> Function(DmChannel) onOpenDm;

  @override
  Widget build(BuildContext context) {
    final selfId = controller.user?.id ?? '';

    return Material(
      color: kSidebar,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _startChat(context),
              child: Container(
                height: 36,
                decoration: BoxDecoration(
                  color: kRail,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: const Text(
                  'Найти или начать беседу',
                  style: TextStyle(fontSize: 12, color: kTextMuted),
                ),
              ),
            ),
          ),
          ListenableBuilder(
            listenable: controller.friends,
            builder: (context, _) {
              final pending = controller.friends.pendingCount;
              return ListTile(
                dense: true,
                leading: const Icon(Icons.people_alt, size: 20),
                title: const Text(
                  'Друзья',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                trailing: pending > 0
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: kDanger,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$pending',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => FriendsScreen(controller: controller),
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1, color: Color(0xFF1E1F22)),
          Row(
            children: [
              const Expanded(child: _GroupLabel('ЛИЧНЫЕ СООБЩЕНИЯ')),
              IconButton(
                tooltip: 'Новая группа',
                onPressed: () => _createGroupChat(context, controller),
                icon: const Icon(Icons.group_add, size: 18),
              ),
              IconButton(
                tooltip: 'Новый диалог',
                onPressed: () => _startChat(context),
                icon: const Icon(Icons.add, size: 18),
              ),
            ],
          ),
          Expanded(
            child: controller.dms.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Нажмите «+», чтобы начать беседу',
                      style: TextStyle(fontSize: 11, color: kTextMuted),
                    ),
                  )
                : ListView.builder(
                    itemCount: controller.dms.length,
                    itemBuilder: (context, index) {
                      final dm = controller.dms[index];
                      return _DmHomeTile(
                        dm: dm,
                        selfId: selfId,
                        unread: controller.dmUnread(dm.id),
                        selected: controller.dm?.id == dm.id,
                        onTap: () => onOpenDm(dm),
                      );
                    },
                  ),
          ),
          _UserFooter(controller: controller),
        ],
      ),
    );
  }

  Future<void> _startChat(BuildContext context) async {
    final userID = await showDialog<String>(
      context: context,
      builder: (_) => _StartChatDialog(controller: controller),
    );
    if (userID == null || !context.mounted) return;

    final ok = await controller.startDm(userID);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.error ?? 'Не удалось начать беседу')),
      );
      return;
    }
    final dm = controller.dm;
    if (dm != null) await onOpenDm(dm);
  }
}

/// Строка диалога: аватар с инициалом, имя, подпись, счётчик.
class _DmHomeTile extends StatelessWidget {
  const _DmHomeTile({
    required this.dm,
    required this.selfId,
    required this.unread,
    required this.selected,
    required this.onTap,
  });

  final DmChannel dm;
  final String selfId;
  final int unread;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final other = dm.recipients.firstWhere(
      (p) => p.userId != selfId,
      orElse: () => dm.recipients.isEmpty
          ? const DmParticipant(userId: '', username: '?')
          : dm.recipients.first,
    );
    final title = dm.title(selfId);
    final preview = dm.lastMessage;
    final subtitle = preview != null
        ? preview.preview
        : dm.isGroup
        ? '${dm.recipients.length} участника'
        : '@${other.username}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? const Color(0xFF404249) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: kAccent,
                  child: Text(
                    title.isEmpty ? '?' : title[0].toUpperCase(),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: unread > 0 ? kTextPrimary : kTextMuted,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: kTextMuted),
                      ),
                    ],
                  ),
                ),
                if (unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: kDanger,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Поиск человека, чтобы начать беседу. Возвращает user_id.
class _StartChatDialog extends StatefulWidget {
  const _StartChatDialog({required this.controller});

  final AppController controller;

  @override
  State<_StartChatDialog> createState() => _StartChatDialogState();
}

class _StartChatDialogState extends State<_StartChatDialog> {
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Чистим только результаты поиска: список друзей и заявок не трогаем.
    widget.controller.friends.clearSearch();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final friends = widget.controller.friends;
    return AlertDialog(
      title: const Text('Начать беседу'),
      content: SizedBox(
        width: 360,
        height: 320,
        child: Column(
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Логин или имя',
                helperText: 'Минимум 2 символа',
              ),
              onSubmitted: friends.search,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListenableBuilder(
                listenable: friends,
                builder: (context, _) {
                  if (friends.searching) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (friends.results.isEmpty) {
                    return const Center(
                      child: Text(
                        'Введите минимум 2 символа и нажмите Enter',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: kTextMuted),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: friends.results.length,
                    itemBuilder: (context, index) {
                      final result = friends.results[index];
                      return ListTile(
                        dense: true,
                        title: Text(result.name),
                        subtitle: Text(
                          '@${result.username}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: kTextMuted,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(result.id),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}

/// Настройки микрофона: выбор устройства, уровень, обработка голоса.
class _MicSettingsDialog extends StatelessWidget {
  const _MicSettingsDialog({required this.voice});

  final VoiceController voice;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Микрофон'),
      content: SizedBox(
        width: 380,
        child: ListenableBuilder(
          listenable: voice,
          builder: (context, _) {
            final inputs = voice.audioInputs;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
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
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue:
                      inputs.any((d) => d.deviceId == voice.selectedMicId)
                      ? voice.selectedMicId
                      : null,
                  decoration: const InputDecoration(
                    labelText: 'Устройство ввода',
                  ),
                  items: [
                    for (final device in inputs)
                      DropdownMenuItem(
                        value: device.deviceId,
                        child: Text(
                          device.label.isEmpty
                              ? 'Микрофон ${device.deviceId}'
                              : device.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == null) return;
                    for (final device in inputs) {
                      if (device.deviceId == id) {
                        voice.selectMicrophone(device);
                        break;
                      }
                    }
                  },
                ),
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: voice.loadAudioInputs,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Обновить список устройств'),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Обработка голоса'),
                  subtitle: const Text(
                    'Шумоподавление и выравнивание громкости. Выключите, '
                    'если голос звучит «ватно» или металлически.',
                    style: TextStyle(fontSize: 11, color: kTextMuted),
                  ),
                  value: voice.audioProcessing,
                  onChanged: (_) => voice.toggleAudioProcessing(),
                ),
              ],
            );
          },
        ),
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

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 6),
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

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.selected,
    required this.onTap,
  });

  final Channel channel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? const Color(0xFF404249) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Icon(
                  channel.isVoice ? Icons.volume_up : Icons.tag,
                  size: 18,
                  color: kTextMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? kTextPrimary : kTextMuted,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DmTile extends StatelessWidget {
  const _DmTile({
    required this.dm,
    required this.selfId,
    required this.unread,
    required this.selected,
    required this.onTap,
  });

  final DmChannel dm;
  final String selfId;
  final int unread;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? const Color(0xFF404249) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.person, size: 18, color: kTextMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dm.title(selfId),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? kTextPrimary : kTextMuted,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      if (dm.lastMessage != null)
                        Text(
                          dm.lastMessage!.preview,
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
                if (unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: kDanger,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UserFooter extends StatelessWidget {
  const _UserFooter({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final status = controller.gatewayStatus;
    final online = status == GatewayStatus.connected;

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: const Color(0xFF232428),
      child: Row(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: kAccent,
            child: Text(
              controller.user?.name.substring(0, 1).toUpperCase() ?? '?',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.user?.name ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: online ? kOnline : kTextMuted,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        online ? 'в сети' : 'подключение…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: kTextMuted),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'v$kAppVersion',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: kTextMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Выйти',
            onPressed: controller.logout,
            icon: const Icon(Icons.logout, size: 18),
          ),
        ],
      ),
    );
  }
}

class ChannelPane extends StatelessWidget {
  const ChannelPane({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final channel = controller.channel;

    if (channel == null) {
      return const ColoredBox(
        color: kBackground,
        child: Center(
          child: Text('Выберите канал', style: TextStyle(color: kTextMuted)),
        ),
      );
    }

    if (channel.isDm) {
      return ListenableBuilder(
        listenable: controller.voice,
        builder: (context, _) {
          final inCall =
              controller.voice.channelId == channel.id &&
              controller.voice.connected;
          if (inCall) {
            return _VoicePanel(controller: controller, channel: channel);
          }
          return _TextChannel(controller: controller, channel: channel);
        },
      );
    }

    if (channel.isVoice) {
      return _VoicePanel(controller: controller, channel: channel);
    }

    return _TextChannel(controller: controller, channel: channel);
  }
}

class _TextChannel extends StatefulWidget {
  const _TextChannel({required this.controller, required this.channel});

  final AppController controller;
  final Channel channel;

  @override
  State<_TextChannel> createState() => _TextChannelState();
}

class _TextChannelState extends State<_TextChannel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _picking = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _groupAction(String action) async {
    final controller = widget.controller;

    switch (action) {
      case 'members':
        await showDialog<void>(
          context: context,
          builder: (_) => _GroupMembersDialog(controller: controller),
        );
        return;
      case 'rename':
        final name = await _prompt(context, 'Название группы', 'Имя');
        if (name == null || !mounted) return;
        final ok = await controller.renameDm(
          name.trim().isEmpty ? null : name.trim(),
        );
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(controller.error ?? 'Не удалось переименовать'),
            ),
          );
        }
        return;
      case 'leave':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Выйти из группы?'),
            content: const Text('Переписка останется у остальных участников.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Выйти'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;

        final selfId = controller.user?.id;
        if (selfId == null) return;
        final ok = await controller.removeDmMember(selfId);
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(controller.error ?? 'Не удалось выйти')),
          );
        }
        return;
    }
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;

    _input.clear();
    await widget.controller.sendMessage(text);
  }

  Future<void> _pickAndSend() async {
    if (_picking || widget.controller.sending) return;

    setState(() => _picking = true);

    try {
      final files = await FilePicker.pickFiles();
      if (files.isEmpty) return;

      final file = files.first;
      final bytes = await file.readAsBytes();

      final ok = await widget.controller.sendWithAttachment(
        filename: file.name,
        contentType: _contentTypeFor(file.name),
        bytes: bytes,
        text: _input.text,
      );

      if (ok) {
        _input.clear();
      } else if (widget.controller.error != null && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(widget.controller.error!)));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  String _contentTypeFor(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'pdf' => 'application/pdf',
      'txt' => 'text/plain',
      'json' => 'application/json',
      'zip' => 'application/zip',
      'mp3' => 'audio/mpeg',
      'mp4' => 'video/mp4',
      _ => 'application/octet-stream',
    };
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final messages = controller.messages;

    return ColoredBox(
      color: kBackground,
      child: Column(
        children: [
          _ChannelHeader(
            icon: widget.channel.isDm ? Icons.person : Icons.tag,
            title: widget.channel.name,
            subtitle: widget.channel.isDm
                ? 'личные сообщения'
                : controller.gatewayStatus == GatewayStatus.connected
                ? 'живые сообщения'
                : 'переподключение…',
            trailing: widget.channel.isDm
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (controller.dm?.isGroup == true)
                        PopupMenuButton<String>(
                          tooltip: 'Группа',
                          onSelected: _groupAction,
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'members',
                              child: Text('Участники'),
                            ),
                            PopupMenuItem(
                              value: 'rename',
                              child: Text('Переименовать'),
                            ),
                            PopupMenuItem(
                              value: 'leave',
                              child: Text('Выйти из группы'),
                            ),
                          ],
                        ),
                      IconButton(
                        tooltip: controller.dm?.isGroup == true
                            ? 'Позвонить группе'
                            : 'Позвонить',
                        onPressed: () => controller.startDmCall(widget.channel),
                        icon: const Icon(Icons.call, size: 20),
                      ),
                    ],
                  )
                : null,
          ),
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text(
                      controller.loadingMessages
                          ? 'Загружаю сообщения…'
                          : 'Пока тихо. Напишите первым.',
                      style: const TextStyle(color: kTextMuted),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    itemCount: messages.length + (controller.hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == messages.length) {
                        return Center(
                          child: TextButton(
                            onPressed: controller.loadingMessages
                                ? null
                                : controller.loadOlder,
                            child: const Text('Загрузить ещё'),
                          ),
                        );
                      }

                      final message = messages[messages.length - 1 - index];
                      return _MessageTile(
                        message: message,
                        authorName: controller.memberName(message.authorId),
                      );
                    },
                  ),
          ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                controller.error!,
                style: const TextStyle(color: kDanger, fontSize: 12),
              ),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: widget.channel.isDm
                          ? 'Написать в личные сообщения'
                          : 'Написать в #${widget.channel.name}',
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Прикрепить файл',
                  onPressed: (controller.sending || _picking)
                      ? null
                      : _pickAndSend,
                  icon: _picking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.attach_file),
                ),
                IconButton.filled(
                  onPressed: controller.sending ? null : _send,
                  icon: controller.sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, required this.authorName});

  final Message message;
  final String authorName;

  @override
  Widget build(BuildContext context) {
    final time =
        '${message.createdAt.hour.toString().padLeft(2, '0')}:'
        '${message.createdAt.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: const Color(0xFF5865F2),
            child: Text(
              authorName.isEmpty
                  ? '?'
                  : authorName.substring(0, 1).toUpperCase(),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      authorName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      time,
                      style: const TextStyle(fontSize: 11, color: kTextMuted),
                    ),
                    if (message.isEdited) ...[
                      const SizedBox(width: 6),
                      const Text(
                        '(изменено)',
                        style: TextStyle(fontSize: 11, color: kTextMuted),
                      ),
                    ],
                  ],
                ),
                if (message.content.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(message.content),
                  ),
                for (final attachment in message.attachments)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: kSidebar,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.attach_file,
                            size: 16,
                            color: kTextMuted,
                          ),
                          const SizedBox(width: 6),
                          Text(attachment.filename),
                          const SizedBox(width: 8),
                          Text(
                            attachment.sizeLabel,
                            style: const TextStyle(
                              fontSize: 11,
                              color: kTextMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VoicePanel extends StatelessWidget {
  const _VoicePanel({required this.controller, required this.channel});

  final AppController controller;
  final Channel channel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.voice,
      builder: (context, _) {
        final voice = controller.voice;
        final inThisChannel = voice.channelId == channel.id && voice.connected;

        return ColoredBox(
          color: kBackground,
          child: Column(
            children: [
              _ChannelHeader(
                icon: Icons.volume_up,
                title: channel.name,
                subtitle: inThisChannel
                    ? 'вы в голосовом канале'
                    : 'голосовой канал',
              ),
              if (inThisChannel &&
                  (voice.screenShareTrack != null ||
                      voice.cameraTiles.isNotEmpty))
                SizedBox(height: 240, child: _VideoStrip(voice: voice)),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.graphic_eq,
                            size: 64,
                            color: kAccent,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            inThisChannel
                                ? 'Подключено'
                                : 'Голосовой канал «${channel.name}»',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            inThisChannel
                                ? 'Микрофон ${voice.micEnabled ? 'включён' : 'выключен'}, '
                                      'звук ${voice.deafened ? 'выключен' : 'включён'}'
                                : 'Нажмите, чтобы войти. Микрофон включится сразу.',
                            style: const TextStyle(color: kTextMuted),
                            textAlign: TextAlign.center,
                          ),
                          if (voice.error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              voice.error!,
                              style: const TextStyle(color: kDanger),
                              textAlign: TextAlign.center,
                            ),
                          ],
                          if (controller.callNotice != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              controller.callNotice!,
                              style: const TextStyle(color: kDanger),
                              textAlign: TextAlign.center,
                            ),
                          ],
                          const SizedBox(height: 20),
                          if (!inThisChannel)
                            ElevatedButton.icon(
                              onPressed: voice.connecting
                                  ? null
                                  : () => controller.joinVoice(channel),
                              icon: voice.connecting
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.headset_mic),
                              label: const Text('Подключиться'),
                            )
                          else
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                FilledButton.icon(
                                  onPressed: voice.toggleMicrophone,
                                  icon: Icon(
                                    voice.micEnabled
                                        ? Icons.mic
                                        : Icons.mic_off,
                                  ),
                                  label: Text(
                                    voice.micEnabled
                                        ? 'Выключить микрофон'
                                        : 'Включить микрофон',
                                  ),
                                ),
                                if (voice.canVideo)
                                  OutlinedButton.icon(
                                    onPressed: voice.toggleCamera,
                                    icon: Icon(
                                      voice.cameraEnabled
                                          ? Icons.videocam
                                          : Icons.videocam_off,
                                    ),
                                    label: Text(
                                      voice.cameraEnabled
                                          ? 'Выключить камеру'
                                          : 'Включить камеру',
                                    ),
                                  ),
                                if (voice.canScreenShare)
                                  OutlinedButton.icon(
                                    onPressed: voice.toggleScreenShare,
                                    icon: const Icon(Icons.screen_share),
                                    label: Text(
                                      voice.screenSharing
                                          ? 'Остановить показ'
                                          : 'Показать экран',
                                    ),
                                  ),
                                OutlinedButton.icon(
                                  onPressed: voice.toggleDeafen,
                                  icon: Icon(
                                    voice.deafened
                                        ? Icons.volume_off
                                        : Icons.volume_up,
                                  ),
                                  label: Text(
                                    voice.deafened
                                        ? 'Включить звук'
                                        : 'Оглушить',
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: controller.leaveVoice,
                                  icon: const Icon(Icons.call_end),
                                  label: const Text('Выйти'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => showDialog<void>(
                                    context: context,
                                    builder: (_) =>
                                        _MicSettingsDialog(voice: voice),
                                  ),
                                  icon: const Icon(Icons.settings_voice),
                                  label: const Text('Микрофон'),
                                ),
                              ],
                            ),
                          if (inThisChannel) ...[
                            const SizedBox(height: 28),
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'УЧАСТНИКИ',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: kTextMuted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (voice.participants.isEmpty)
                              const Text(
                                'Пока никого',
                                style: TextStyle(color: kTextMuted),
                              )
                            else
                              Column(
                                children: [
                                  for (final participant in voice.participants)
                                    ListTile(
                                      dense: true,
                                      tileColor:
                                          voice.isSpeaking(participant.userId)
                                          ? kAccent.withValues(alpha: 0.22)
                                          : null,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      leading: CircleAvatar(
                                        radius: 14,
                                        backgroundColor: kAccent,
                                        child: Text(
                                          participant.name
                                              .substring(0, 1)
                                              .toUpperCase(),
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      title: Text(participant.name),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (voice.isSpeaking(
                                            participant.userId,
                                          ))
                                            const Padding(
                                              padding: EdgeInsets.only(
                                                right: 6,
                                              ),
                                              child: Icon(
                                                Icons.graphic_eq,
                                                size: 16,
                                                color: kOnline,
                                              ),
                                            ),
                                          Icon(
                                            participant.selfMute
                                                ? Icons.mic_off
                                                : Icons.mic,
                                            size: 16,
                                            color: kTextMuted,
                                          ),
                                          if (participant.selfDeaf)
                                            const Padding(
                                              padding: EdgeInsets.only(left: 4),
                                              child: Icon(
                                                Icons.volume_off,
                                                size: 16,
                                                color: kTextMuted,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _VideoStrip extends StatelessWidget {
  const _VideoStrip({required this.voice});

  final VoiceController voice;

  @override
  Widget build(BuildContext context) {
    final screen = voice.screenShareTrack;
    if (screen != null) {
      return ColoredBox(
        color: Colors.black,
        child: GestureDetector(
          onTap: () => _openFullScreen(context, screen),
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoTrackRenderer(screen, fit: VideoViewFit.contain),
              const Positioned(
                right: 8,
                top: 8,
                child: Icon(Icons.fullscreen, color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }

    final tiles = voice.cameraTiles;

    return ColoredBox(
      color: Colors.black,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(8),
        itemCount: tiles.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final tile = tiles[index];
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 240,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  VideoTrackRenderer(tile.track, fit: VideoViewFit.cover),
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        tile.name,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openFullScreen(BuildContext context, VideoTrack track) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: const Text('Демонстрация экрана'),
          ),
          body: Center(child: VideoTrackRenderer(track)),
        ),
      ),
    );
  }
}

class _ChannelHeader extends StatelessWidget {
  const _ChannelHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF1E1F22))),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: kTextMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 11, color: kTextMuted),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

class _NewDmDialog extends StatelessWidget {
  const _NewDmDialog({required this.members, required this.selfId});

  final List<GuildMember> members;
  final String selfId;

  @override
  Widget build(BuildContext context) {
    final others = members.where((m) => m.userId != selfId).toList();

    return AlertDialog(
      title: const Text('Новый диалог'),
      content: SizedBox(
        width: 320,
        child: others.isEmpty
            ? const Text(
                'В текущем сервере больше никого нет. Пригласите участника '
                'или выберите другой сервер.',
                style: TextStyle(color: kTextMuted),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: others.length,
                itemBuilder: (context, index) {
                  final member = others[index];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: kAccent,
                      child: Text(
                        member.name.substring(0, 1).toUpperCase(),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    title: Text(member.name),
                    subtitle: Text(
                      '@${member.username}',
                      style: const TextStyle(fontSize: 11, color: kTextMuted),
                    ),
                    onTap: () => Navigator.of(context).pop(member),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}

class _CreateChannelDialog extends StatefulWidget {
  const _CreateChannelDialog();

  @override
  State<_CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<_CreateChannelDialog> {
  final _name = TextEditingController();
  String _type = 'text';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Новый канал'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Название'),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'text', label: Text('Текстовый')),
              ButtonSegment(value: 'voice', label: Text('Голосовой')),
            ],
            selected: {_type},
            onSelectionChanged: (value) => setState(() => _type = value.first),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop((name: name, type: _type));
          },
          child: const Text('Создать'),
        ),
      ],
    );
  }
}

Future<String?> _prompt(
  BuildContext context,
  String title,
  String label,
) async {
  final controller = TextEditingController();

  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Создать'),
        ),
      ],
    ),
  );

  controller.dispose();
  return result;
}

/// Диалог создания группы: выбор друзей и необязательное имя.
Future<void> _createGroupChat(
  BuildContext context,
  AppController controller,
) async {
  final result = await showDialog<({List<String> ids, String? name})>(
    context: context,
    builder: (_) => _NewGroupDialog(controller: controller),
  );
  if (result == null || !context.mounted) return;

  final ok = await controller.createGroup(result.ids, result.name);
  if (!context.mounted) return;
  if (!ok) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(controller.error ?? 'Не удалось создать группу')),
    );
  }
}

class _NewGroupDialog extends StatefulWidget {
  const _NewGroupDialog({required this.controller});

  final AppController controller;

  @override
  State<_NewGroupDialog> createState() => _NewGroupDialogState();
}

class _NewGroupDialogState extends State<_NewGroupDialog> {
  final _name = TextEditingController();
  final Set<String> _selected = {};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selfId = widget.controller.user?.id ?? '';

    return AlertDialog(
      title: const Text('Новая группа'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Название (необязательно)',
              ),
            ),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: widget.controller.friends,
              builder: (context, _) {
                final friends = [
                  for (final entry in widget.controller.friends.view.friends)
                    if (entry.user.id != selfId) entry.user,
                ];

                if (friends.isEmpty) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Сначала добавьте друзей: группа собирается из них.',
                        style: TextStyle(color: kTextMuted),
                      ),
                      TextButton.icon(
                        onPressed: widget.controller.friends.load,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Обновить'),
                      ),
                    ],
                  );
                }

                return SizedBox(
                  height: 280,
                  child: ListView.builder(
                    itemCount: friends.length,
                    itemBuilder: (context, index) {
                      final user = friends[index];
                      return CheckboxListTile(
                        dense: true,
                        value: _selected.contains(user.id),
                        title: Text(user.name),
                        subtitle: Text(
                          '@${user.username}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: kTextMuted,
                          ),
                        ),
                        onChanged: (checked) {
                          setState(() {
                            if (checked == true) {
                              _selected.add(user.id);
                            } else {
                              _selected.remove(user.id);
                            }
                          });
                        },
                      );
                    },
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Выбрано ${_selected.length} · нужно минимум 2',
              style: const TextStyle(fontSize: 11, color: kTextMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _selected.length < 2
              ? null
              : () {
                  final name = _name.text.trim();
                  Navigator.of(context).pop((
                    ids: _selected.toList(),
                    name: name.isEmpty ? null : name,
                  ));
                },
          child: const Text('Создать'),
        ),
      ],
    );
  }
}

/// Участники группы: список, добавление и удаление.
class _GroupMembersDialog extends StatelessWidget {
  const _GroupMembersDialog({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final dm = controller.dm;
        if (dm == null) {
          return const AlertDialog(
            title: Text('Участники'),
            content: Text('Группа больше не открыта.'),
          );
        }

        return AlertDialog(
          title: const Text('Участники группы'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 280,
                  child: ListView(
                    children: [
                      for (final participant in dm.recipients)
                        ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            radius: 14,
                            backgroundColor: kAccent,
                            child: Text(
                              participant.name.isEmpty
                                  ? '?'
                                  : participant.name
                                        .substring(0, 1)
                                        .toUpperCase(),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          title: Text(participant.name),
                          subtitle: Text(
                            '@${participant.username}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: kTextMuted,
                            ),
                          ),
                          trailing:
                              participant.userId == controller.user?.id
                              ? const Text(
                                  'вы',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: kTextMuted,
                                  ),
                                )
                              : IconButton(
                                  tooltip: 'Убрать из группы',
                                  icon: const Icon(Icons.person_remove, size: 18),
                                  onPressed: () => _remove(
                                    context,
                                    dm.id,
                                    participant,
                                  ),
                                ),
                        ),
                    ],
                  ),
                ),
                if (dm.recipients.length < 10)
                  TextButton.icon(
                    onPressed: () => _add(context, dm),
                    icon: const Icon(Icons.person_add_alt, size: 18),
                    label: const Text('Добавить участника'),
                  )
                else
                  const Text(
                    'В группе уже 10 участников.',
                    style: TextStyle(fontSize: 11, color: kTextMuted),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Готово'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _remove(
    BuildContext context,
    String channelId,
    DmParticipant participant,
  ) async {
    final ok = await controller.removeDmMember(participant.userId);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.error ?? 'Не удалось убрать')),
      );
    }
  }

  Future<void> _add(BuildContext context, DmChannel dm) async {
    final selfId = controller.user?.id ?? '';
    final inGroup = {for (final p in dm.recipients) p.userId};
    final candidates = [
      for (final entry in controller.friends.view.friends)
        if (entry.user.id != selfId && !inGroup.contains(entry.user.id))
          entry.user,
    ];

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Все друзья уже в группе или их нет')),
      );
      return;
    }

    final user = await showDialog<User>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Добавить в группу'),
        content: SizedBox(
          width: 320,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (context, index) {
              final user = candidates[index];
              return ListTile(
                dense: true,
                title: Text(user.name),
                subtitle: Text(
                  '@${user.username}',
                  style: const TextStyle(fontSize: 11, color: kTextMuted),
                ),
                onTap: () => Navigator.of(context).pop(user),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
        ],
      ),
    );
    if (user == null || !context.mounted) return;

    final ok = await controller.addDmMember(user.id);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.error ?? 'Не удалось добавить')),
      );
    }
  }
}
