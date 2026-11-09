import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/config.dart';

enum GatewayStatus { disconnected, connecting, connected }

class GatewayEvent {
  const GatewayEvent(this.type, this.data);

  final String type;
  final dynamic data;
}

/// Клиент WebSocket-шлюза.
///
/// Протокол:
///   HELLO → IDENTIFY/RESUME → READY/RESUMED → DISPATCH.
/// При обрыве переподключается и просит догнать события через RESUME.
class GatewayClient {
  GatewayClient({
    String? url,
    required this.tokenProvider,
  }) : url = url ?? gatewayUrl;

  final String url;
  final Future<String> Function() tokenProvider;

  final _events = StreamController<GatewayEvent>.broadcast();
  final _statuses = StreamController<GatewayStatus>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnect;

  String? _sessionId;
  int _seq = 0;
  int _attempt = 0;
  bool _disposed = false;
  bool _connecting = false;

  GatewayStatus _status = GatewayStatus.disconnected;

  Stream<GatewayEvent> get events => _events.stream;
  Stream<GatewayStatus> get statuses => _statuses.stream;
  GatewayStatus get status => _status;

  Future<void> connect() async {
    if (_disposed || _connecting) return;
    _connecting = true;
    _setStatus(GatewayStatus.connecting);

    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      await channel.ready;
      _channel = channel;

      _subscription?.cancel();
      _subscription = channel.stream.listen(
        _onFrame,
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
        cancelOnError: true,
      );
    } catch (_) {
      _onDisconnected();
      return;
    } finally {
      _connecting = false;
    }
  }

  Future<void> _onFrame(dynamic raw) async {
    if (raw is! String) return;

    late final Map<String, dynamic> frame;
    try {
      frame = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final op = frame['op'] as int? ?? -1;
    final type = frame['t'] as String?;
    final seq = (frame['s'] as num?)?.toInt();
    final data = frame['d'];

    switch (op) {
      case 10: // HELLO
        final interval = (data is Map ? data['heartbeat_interval'] : null);
        _startHeartbeat(
          interval is num ? interval.toInt() : 41250,
        );
        await _sendHandshake();
        break;
      case 0: // DISPATCH
        if (seq != null) _seq = seq;

        if (type == 'READY') {
          _sessionId = (data as Map<String, dynamic>)['session_id'] as String?;
          _attempt = 0;
          _setStatus(GatewayStatus.connected);
        } else if (type == 'RESUMED') {
          _attempt = 0;
          _setStatus(GatewayStatus.connected);
        }

        if (type != null) {
          _events.add(GatewayEvent(type, data));
        }
        break;
      case 9: // INVALID_SESSION
        _sessionId = null;
        _seq = 0;
        _setStatus(GatewayStatus.connecting);
        break;
      case 11: // HEARTBEAT_ACK
        break;
    }
  }

  Future<void> _sendHandshake() async {
    final token = await tokenProvider();

    if (_sessionId != null) {
      _send({
        'op': 6,
        'd': {
          'token': token,
          'session_id': _sessionId,
          'seq': _seq,
        },
      });
      return;
    }

    _send({
      'op': 2,
      'd': {'token': token},
    });
  }

  void _startHeartbeat(int intervalMs) {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => _send({'op': 1}),
    );
  }

  void _send(Map<String, dynamic> frame) {
    try {
      _channel?.sink.add(jsonEncode(frame));
    } catch (_) {
      _onDisconnected();
    }
  }

  void _onDisconnected() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;

    if (_disposed) return;

    _setStatus(GatewayStatus.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || _reconnect != null) return;

    const delays = [1, 2, 5, 10, 20, 30];
    final seconds = delays[min(_attempt, delays.length - 1)];
    _attempt++;

    _reconnect = Timer(Duration(seconds: seconds), () {
      _reconnect = null;
      connect();
    });
  }

  void _setStatus(GatewayStatus value) {
    if (_status == value) return;
    _status = value;
    if (!_statuses.isClosed) _statuses.add(value);
  }

  Future<void> dispose() async {
    _disposed = true;
    _heartbeat?.cancel();
    _reconnect?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    await _events.close();
    await _statuses.close();
  }
}
