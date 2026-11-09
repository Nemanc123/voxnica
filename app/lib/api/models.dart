/// Модели данных, которые приходят от API.
///
/// Здесь нет логики — только разбор JSON и удобные геттеры.
library;

class User {
  const User({
    required this.id,
    required this.username,
    this.displayName,
  });

  final String id;
  final String username;
  final String? displayName;

  String get name =>
      (displayName != null && displayName!.trim().isNotEmpty)
          ? displayName!
          : username;

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        username: json['username'] as String? ?? '',
        displayName: json['display_name'] as String?,
      );
}

class AuthSession {
  const AuthSession({
    required this.user,
    required this.accessToken,
    required this.refreshToken,
    this.expiresAt,
  });

  final User user;
  final String accessToken;
  final String refreshToken;
  final DateTime? expiresAt;

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final expiresIn = (json['expires_in'] as num?)?.toInt();
    return AuthSession(
      user: User.fromJson(json['user'] as Map<String, dynamic>),
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      expiresAt: expiresIn == null
          ? null
          : DateTime.now().add(Duration(seconds: expiresIn)),
    );
  }
}

class Guild {
  const Guild({required this.id, required this.name});

  final String id;
  final String name;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    final first = parts.first[0].toUpperCase();
    if (parts.length == 1) return first;
    return first + parts[1][0].toUpperCase();
  }

  factory Guild.fromJson(Map<String, dynamic> json) => Guild(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Без названия',
      );
}

class Channel {
  const Channel({
    required this.id,
    required this.name,
    required this.type,
  });

  final String id;
  final String name;
  final String type;

  bool get isVoice => type == 'voice';
  bool get isText => type == 'text';

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? 'без имени',
        type: json['type'] as String? ?? 'text',
      );
}

class GuildDetail {
  const GuildDetail({required this.guild, required this.channels});

  final Guild guild;
  final List<Channel> channels;

  factory GuildDetail.fromJson(Map<String, dynamic> json) {
    final rawChannels = (json['channels'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .where((c) => c['type'] == 'text' || c['type'] == 'voice')
        .map(Channel.fromJson)
        .toList();

    return GuildDetail(
      guild: Guild.fromJson(json['guild'] as Map<String, dynamic>),
      channels: rawChannels,
    );
  }
}

class Attachment {
  const Attachment({
    required this.id,
    required this.filename,
    required this.contentType,
    required this.sizeBytes,
    required this.storageKey,
  });

  final String id;
  final String filename;
  final String contentType;
  final int sizeBytes;
  final String storageKey;

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes Б';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} КБ';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
        id: json['id'] as String,
        filename: json['filename'] as String? ?? 'файл',
        contentType: json['content_type'] as String? ?? '',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        storageKey: json['storage_key'] as String? ?? '',
      );
}

class Message {
  const Message({
    required this.id,
    required this.seq,
    required this.channelId,
    required this.authorId,
    required this.content,
    required this.createdAt,
    this.editedAt,
    this.attachments = const [],
  });

  final String id;
  final int seq;
  final String channelId;
  final String? authorId;
  final String content;
  final DateTime createdAt;
  final DateTime? editedAt;
  final List<Attachment> attachments;

  bool get isEdited => editedAt != null;

  String get authorLabel {
    final id = authorId;
    if (id == null) return 'система';
    return id.length >= 8 ? id.substring(0, 8) : id;
  }

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        seq: (json['seq'] as num).toInt(),
        channelId: json['channel_id'] as String,
        authorId: json['author_id'] as String?,
        content: json['content'] as String? ?? '',
        createdAt:
            DateTime.tryParse(json['created_at'] as String? ?? '')?.toLocal() ??
                DateTime.now(),
        editedAt:
            DateTime.tryParse(json['edited_at'] as String? ?? '')?.toLocal(),
        attachments: (json['attachments'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>()
            .map(Attachment.fromJson)
            .toList(),
      );
}

class VoiceJoinInfo {
  const VoiceJoinInfo({
    required this.token,
    required this.url,
    required this.room,
    required this.canPublish,
  });

  final String token;
  final String url;
  final String room;
  final bool canPublish;

  factory VoiceJoinInfo.fromJson(Map<String, dynamic> json) => VoiceJoinInfo(
        token: json['token'] as String,
        url: json['url'] as String,
        room: json['room'] as String,
        canPublish: json['can_publish'] as bool? ?? false,
      );
}

class VoiceParticipant {
  const VoiceParticipant({
    required this.userId,
    required this.username,
    this.displayName,
    required this.selfMute,
  });

  final String userId;
  final String username;
  final String? displayName;
  final bool selfMute;

  String get name =>
      (displayName != null && displayName!.trim().isNotEmpty)
          ? displayName!
          : username;

  factory VoiceParticipant.fromJson(Map<String, dynamic> json) =>
      VoiceParticipant(
        userId: json['user_id'] as String,
        username: json['username'] as String? ?? 'участник',
        displayName: json['display_name'] as String?,
        selfMute: json['self_mute'] as bool? ?? false,
      );
}
