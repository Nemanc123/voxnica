import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../gateway/gateway_client.dart';
import '../state/app_controller.dart';
import '../theme.dart';
import 'channel_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 850;

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _GuildRail(controller: controller),
            if (wide) ...[
              SizedBox(
                width: 250,
                child: _ChannelSidebar(
                  controller: controller,
                  onOpenChannel: controller.selectChannel,
                ),
              ),
              const VerticalDivider(width: 1, color: Color(0xFF1E1F22)),
              Expanded(child: ChannelPane(controller: controller)),
            ] else
              Expanded(
                child: _ChannelSidebar(
                  controller: controller,
                  onOpenChannel: (channel) async {
                    await controller.selectChannel(channel);
                    if (!context.mounted) return;
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ChannelScreen(controller: controller),
                      ),
                    );
                  },
                ),
              ),
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
  });

  final AppController controller;
  final Future<void> Function(Channel) onOpenChannel;

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
              border: Border(
                bottom: BorderSide(color: Color(0xFF1E1F22)),
              ),
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
                if (guild != null)
                  IconButton(
                    tooltip: 'Создать канал',
                    onPressed: () => _createChannel(context),
                    icon: const Icon(Icons.add, size: 20),
                  ),
              ],
            ),
          ),
          Expanded(
            child: guild == null
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Создайте сервер кнопкой «+» слева',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: kTextMuted),
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      if (controller.textChannels.isNotEmpty)
                        const _GroupLabel('ТЕКСТОВЫЕ КАНАЛЫ'),
                      ...controller.textChannels.map(
                        (channel) => _ChannelTile(
                          channel: channel,
                          selected: controller.channel?.id == channel.id,
                          onTap: () => onOpenChannel(channel),
                        ),
                      ),
                      if (controller.voiceChannels.isNotEmpty)
                        const _GroupLabel('ГОЛОСОВЫЕ КАНАЛЫ'),
                      ...controller.voiceChannels.map(
                        (channel) => _ChannelTile(
                          channel: channel,
                          selected: controller.channel?.id == channel.id,
                          onTap: () => onOpenChannel(channel),
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
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
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
                    Text(
                      online ? 'в сети' : 'подключение…',
                      style: const TextStyle(fontSize: 11, color: kTextMuted),
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
          child: Text(
            'Выберите канал',
            style: TextStyle(color: kTextMuted),
          ),
        ),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.controller.error!)),
        );
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
            icon: Icons.tag,
            title: widget.channel.name,
            subtitle: controller.gatewayStatus == GatewayStatus.connected
                ? 'живые сообщения'
                : 'переподключение…',
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
                    itemCount:
                        messages.length + (controller.hasMore ? 1 : 0),
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

                      final message =
                          messages[messages.length - 1 - index];
                      return _MessageTile(
                        message: message,
                        authorName:
                            controller.memberName(message.authorId),
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
                      hintText: 'Написать в #${widget.channel.name}',
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Прикрепить файл',
                  onPressed:
                      (controller.sending || _picking) ? null : _pickAndSend,
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
    final time = '${message.createdAt.hour.toString().padLeft(2, '0')}:'
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
                      style: const TextStyle(
                        fontSize: 11,
                        color: kTextMuted,
                      ),
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
        final inThisChannel =
            voice.channelId == channel.id && voice.connected;

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
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
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
                                  voice.micEnabled ? Icons.mic : Icons.mic_off,
                                ),
                                label: Text(
                                  voice.micEnabled
                                      ? 'Выключить микрофон'
                                      : 'Включить микрофон',
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
                                for (final participant
                                    in voice.participants)
                                  ListTile(
                                    dense: true,
                                    tileColor: voice.isSpeaking(participant.userId)
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
                                        if (voice.isSpeaking(participant.userId))
                                          const Padding(
                                            padding: EdgeInsets.only(right: 6),
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
            ],
          ),
        );
      },
    );
  }
}

class _ChannelHeader extends StatelessWidget {
  const _ChannelHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

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
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 11, color: kTextMuted),
          ),
        ],
      ),
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
            onSelectionChanged: (value) =>
                setState(() => _type = value.first),
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
