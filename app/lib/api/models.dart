/// Модели данных, которые приходят от API.
///
/// Здесь нет логики — только разбор JSON и удобные геттеры.
library;

class User {
  const User({required this.id, required this.username, this.displayName});

  final String id;
  final String username;
  final String? displayName;

  String get name => (displayName != null && displayName!.trim().isNotEmpty)
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

  /// Формат для локального хранения. Отличается от ответа API:
  /// там `expires_in` в секундах, здесь — абсолютное время.
  Map<String, dynamic> toStorageJson() => {
    'user': {
      'id': user.id,
      'username': user.username,
      'display_name': user.displayName,
    },
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt?.toUtc().toIso8601String(),
  };

  factory AuthSession.fromStorageJson(Map<String, dynamic> json) => AuthSession(
    user: User.fromJson(json['user'] as Map<String, dynamic>),
    accessToken: json['access_token'] as String,
    refreshToken: json['refresh_token'] as String,
    expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
  );
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
  const Channel({required this.id, required this.name, required this.type});

  final String id;
  final String name;
  final String type;

  bool get isVoice => type == 'voice';
  bool get isDm => type == 'dm' || type == 'group_dm';
  bool get isText => type == 'text' || isDm;

  factory Channel.fromJson(Map<String, dynamic> json) => Channel(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? 'без имени',
    type: json['type'] as String? ?? 'text',
  );
}

/// Входящий звонок в личном канале.
class IncomingCall {
  const IncomingCall({
    required this.channelId,
    required this.fromUserId,
    required this.fromName,
  });

  final String channelId;
  final String fromUserId;
  final String fromName;

  factory IncomingCall.fromJson(Map<String, dynamic> json) => IncomingCall(
    channelId: json['channel_id'] as String? ?? '',
    fromUserId: json['from_user_id'] as String? ?? '',
    fromName: json['from_name'] as String? ?? 'Собеседник',
  );
}

/// Собеседник в личном канале.
class DmParticipant {
  const DmParticipant({
    required this.userId,
    required this.username,
    this.displayName,
  });

  final String userId;
  final String username;
  final String? displayName;

  String get name {
    if (displayName != null && displayName!.trim().isNotEmpty) {
      return displayName!;
    }
    return username;
  }

  factory DmParticipant.fromJson(Map<String, dynamic> json) => DmParticipant(
    userId: json['user_id'] as String,
    username: json['username'] as String? ?? 'неизвестный',
    displayName: json['display_name'] as String?,
  );
}

/// Личный канал: id совпадает с id канала сообщений и голосовой комнаты.
/// Последнее сообщение диалога для списка.
class DmLastMessage {
  const DmLastMessage({
    required this.id,
    required this.content,
    this.authorId,
    this.createdAt,
    this.hasAttachments = false,
  });

  final String id;
  final String content;
  final String? authorId;
  final DateTime? createdAt;
  final bool hasAttachments;

  /// Текст для строки превью.
  String get preview {
    final text = content.trim().replaceAll('\n', ' ');
    if (text.isNotEmpty) return text;
    return hasAttachments ? 'Вложение' : 'Сообщение';
  }

  factory DmLastMessage.fromJson(Map<String, dynamic> json) {
    final rawCreated = json['created_at'] as String?;
    return DmLastMessage(
      id: json['id'] as String? ?? '',
      content: json['content'] as String? ?? '',
      authorId: json['author_id'] as String?,
      createdAt: rawCreated == null ? null : DateTime.tryParse(rawCreated),
      hasAttachments: json['has_attachments'] as bool? ?? false,
    );
  }
}

class DmChannel {
  const DmChannel({
    required this.id,
    required this.type,
    required this.recipients,
    this.name,
    this.lastMessage,
    this.unread = 0,
  });

  final String id;
  final String type;
  final String? name;
  final List<DmParticipant> recipients;
  final DmLastMessage? lastMessage;
  final int unread;

  bool get isGroup => type == 'group_dm';

  /// Имя диалога: у группы — заданное имя или список участников,
  /// у пары — собеседник, а не я.
  String title(String selfId) {
    final custom = name?.trim();
    if (custom != null && custom.isNotEmpty) return custom;

    final others = [
      for (final participant in recipients)
        if (participant.userId != selfId) participant.name,
    ];
    if (!isGroup) {
      return others.isEmpty ? 'Личный канал' : others.first;
    }
    if (others.isEmpty) return 'Группа';
    if (others.length <= 3) return others.join(', ');
    return '${others.take(3).join(', ')} +${others.length - 3}';
  }

  factory DmChannel.fromJson(Map<String, dynamic> json) => DmChannel(
    id: json['id'] as String,
    type: json['type'] as String? ?? 'dm',
    name: json['name'] as String?,
    lastMessage: json['last_message'] is Map<String, dynamic>
        ? DmLastMessage.fromJson(json['last_message'] as Map<String, dynamic>)
        : null,
    unread: (json['unread'] as num?)?.toInt() ?? 0,
    recipients: (json['recipients'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(DmParticipant.fromJson)
        .toList(),
  );

  DmChannel withLastMessage(DmLastMessage message) => DmChannel(
    id: id,
    type: type,
    name: name,
    recipients: recipients,
    lastMessage: message,
    unread: unread,
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

class PresignResult {
  const PresignResult({required this.storageKey, required this.uploadUrl});

  final String storageKey;
  final String uploadUrl;

  factory PresignResult.fromJson(Map<String, dynamic> json) => PresignResult(
    storageKey: json['storage_key'] as String,
    uploadUrl: json['upload_url'] as String,
  );
}

class PendingAttachment {
  const PendingAttachment({
    required this.storageKey,
    required this.filename,
    required this.contentType,
    required this.sizeBytes,
  });

  final String storageKey;
  final String filename;
  final String contentType;
  final int sizeBytes;

  Map<String, dynamic> toJson() => {
    'storage_key': storageKey,
    'filename': filename,
    'content_type': contentType,
    'size_bytes': sizeBytes,
  };
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
    editedAt: DateTime.tryParse(json['edited_at'] as String? ?? '')?.toLocal(),
    attachments: (json['attachments'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>()
        .map(Attachment.fromJson)
        .toList(),
  );
}

class GuildMember {
  const GuildMember({
    required this.userId,
    required this.username,
    this.displayName,
    this.nickname,
  });

  final String userId;
  final String username;
  final String? displayName;
  final String? nickname;

  String get name {
    if (nickname != null && nickname!.trim().isNotEmpty) return nickname!;
    if (displayName != null && displayName!.trim().isNotEmpty) {
      return displayName!;
    }
    return username;
  }

  factory GuildMember.fromJson(Map<String, dynamic> json) => GuildMember(
    userId: json['user_id'] as String,
    username: json['username'] as String? ?? 'участник',
    displayName: json['display_name'] as String?,
    nickname: json['nickname'] as String?,
  );
}

class VoiceJoinInfo {
  const VoiceJoinInfo({
    required this.token,
    required this.url,
    required this.room,
    required this.canPublish,
    required this.canSpeak,
    required this.canVideo,
    required this.canScreenShare,
  });

  final String token;
  final String url;
  final String room;
  final bool canPublish;
  final bool canSpeak;
  final bool canVideo;
  final bool canScreenShare;

  factory VoiceJoinInfo.fromJson(Map<String, dynamic> json) => VoiceJoinInfo(
    token: json['token'] as String,
    url: json['url'] as String,
    room: json['room'] as String,
    canPublish: json['can_publish'] as bool? ?? false,
    canSpeak: json['can_speak'] as bool? ?? false,
    canVideo: json['can_video'] as bool? ?? false,
    canScreenShare: json['can_screen_share'] as bool? ?? false,
  );
}

class VoiceParticipant {
  const VoiceParticipant({
    required this.userId,
    required this.username,
    this.displayName,
    required this.selfMute,
    required this.selfDeaf,
  });

  final String userId;
  final String username;
  final String? displayName;
  final bool selfMute;
  final bool selfDeaf;

  String get name => (displayName != null && displayName!.trim().isNotEmpty)
      ? displayName!
      : username;

  factory VoiceParticipant.fromJson(Map<String, dynamic> json) =>
      VoiceParticipant(
        userId: json['user_id'] as String,
        username: json['username'] as String? ?? 'участник',
        displayName: json['display_name'] as String?,
        selfMute: json['self_mute'] as bool? ?? false,
        selfDeaf: json['self_deaf'] as bool? ?? false,
      );
}

/// Запись связи: человек и когда связь появилась.
class RelationshipEntry {
  const RelationshipEntry({required this.user, this.since});

  final User user;
  final DateTime? since;

  factory RelationshipEntry.fromJson(Map<String, dynamic> json) {
    final rawSince = json['since'] as String?;
    return RelationshipEntry(
      user: User.fromJson(json['user'] as Map<String, dynamic>),
      since: rawSince == null ? null : DateTime.tryParse(rawSince),
    );
  }
}

/// Всё, что нужно экрану «Друзья», одним ответом.
class FriendsView {
  const FriendsView({
    required this.friends,
    required this.incoming,
    required this.outgoing,
    required this.blocked,
  });

  const FriendsView.empty()
    : friends = const [],
      incoming = const [],
      outgoing = const [],
      blocked = const [];

  final List<RelationshipEntry> friends;
  final List<RelationshipEntry> incoming;
  final List<RelationshipEntry> outgoing;
  final List<RelationshipEntry> blocked;

  bool get isEmpty =>
      friends.isEmpty &&
      incoming.isEmpty &&
      outgoing.isEmpty &&
      blocked.isEmpty;

  static List<RelationshipEntry> _entries(Object? raw) {
    final list = raw as List<dynamic>? ?? const [];
    return list
        .cast<Map<String, dynamic>>()
        .map(RelationshipEntry.fromJson)
        .toList();
  }

  factory FriendsView.fromJson(Map<String, dynamic> json) => FriendsView(
    friends: _entries(json['friends']),
    incoming: _entries(json['incoming']),
    outgoing: _entries(json['outgoing']),
    blocked: _entries(json['blocked']),
  );
}

/// Результат поиска: человек и отношение к ищущему.
class UserSearchResult {
  const UserSearchResult({
    required this.id,
    required this.username,
    this.displayName,
    this.relation = 'none',
  });

  final String id;
  final String username;
  final String? displayName;
  final String relation; // none | friend | incoming | outgoing | blocked

  String get name => (displayName != null && displayName!.trim().isNotEmpty)
      ? displayName!
      : username;

  factory UserSearchResult.fromJson(Map<String, dynamic> json) =>
      UserSearchResult(
        id: json['id'] as String,
        username: json['username'] as String? ?? '',
        displayName: json['display_name'] as String?,
        relation: json['relation'] as String? ?? 'none',
      );
}
