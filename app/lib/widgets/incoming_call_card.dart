import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme.dart';

/// Карточка входящего звонка поверх любого экрана.
///
/// Живёт в `MaterialApp.builder`, поэтому видна и на домашнем экране,
/// и внутри открытого канала на телефоне.
class IncomingCallCard extends StatelessWidget {
  const IncomingCallCard({
    super.key,
    required this.controller,
    this.onAccepted,
  });

  final AppController controller;
  final VoidCallback? onAccepted;

  @override
  Widget build(BuildContext context) {
    final call = controller.incomingCall;
    if (call == null) return const SizedBox.shrink();

    final dm = controller.dmById(call.channelId);
    final isGroupCall = dm?.isGroup == true;
    final title = isGroupCall
        ? dm!.title(controller.user?.id ?? '')
        : call.fromName;
    final subtitle = isGroupCall ? 'групповой звонок' : 'входящий звонок';

    final initial = title.isEmpty ? '?' : title.substring(0, 1).toUpperCase();

    return Material(
      elevation: 10,
      color: const Color(0xFF2B2D31),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 340,
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: kAccent,
                  child: Text(initial, style: const TextStyle(fontSize: 14)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        subtitle,
                        style: const TextStyle(fontSize: 11, color: kTextMuted),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.call, color: kOnline),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: controller.declineIncomingCall,
                    child: const Text('Отклонить'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      await controller.acceptIncomingCall();
                      onAccepted?.call();
                    },
                    child: const Text('Принять'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
