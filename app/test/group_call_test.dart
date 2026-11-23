import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voxnica/api/models.dart';
import 'package:voxnica/screens/home_screen.dart';
import 'package:voxnica/state/app_controller.dart';
import 'package:voxnica/theme.dart';
import 'package:voxnica/widgets/incoming_call_card.dart';

/// Контроллер без сети: подменяет только состояние, нужное экрану.
class _GroupCallController extends AppController {
  _GroupCallController({
    required this.group,
    required this.groupChannel,
    this.call,
  });

  final DmChannel group;
  final Channel groupChannel;
  final IncomingCall? call;
  String? calledChannelId;

  @override
  DmChannel? get dm => group;

  @override
  List<DmChannel> get dms => [group];

  @override
  Channel? get channel => groupChannel;

  @override
  User? get user => const User(id: 'me', username: 'me');

  @override
  IncomingCall? get incomingCall => call;

  @override
  List<Message> get messages => const [];

  @override
  bool get loadingMessages => false;

  @override
  bool get hasMore => false;

  @override
  Future<void> startDmCall(Channel channel) async {
    calledChannelId = channel.id;
  }
}

void main() {
  const group = DmChannel(
    id: 'group-1',
    type: 'group_dm',
    name: 'Тестовая группа',
    recipients: [
      DmParticipant(userId: 'me', username: 'me'),
      DmParticipant(userId: 'friend', username: 'friend'),
    ],
  );
  const groupChannel = Channel(
    id: 'group-1',
    name: 'Тестовая группа',
    type: 'group_dm',
  );

  testWidgets('в группе есть кнопка «Позвонить группе»', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = _GroupCallController(
      group: group,
      groupChannel: groupChannel,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: HomeScreen(controller: controller),
      ),
    );
    await tester.pump();

    final call = find.byTooltip('Позвонить группе');
    expect(call, findsOneWidget);
    await tester.tap(call);
    await tester.pump();

    expect(controller.calledChannelId, 'group-1');
  });

  testWidgets('входящий групповой звонок показывает название группы', (
    tester,
  ) async {
    final controller = _GroupCallController(
      group: group,
      groupChannel: groupChannel,
      call: const IncomingCall(
        channelId: 'group-1',
        fromUserId: 'friend',
        fromName: 'Друг',
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: IncomingCallCard(controller: controller)),
      ),
    );
    await tester.pump();

    expect(find.text('Тестовая группа'), findsOneWidget);
    expect(find.text('групповой звонок'), findsOneWidget);
    expect(find.text('Друг'), findsNothing);
  });
}
