import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'home_screen.dart';

/// Экран канала для узкого окна: список каналов и лента не помещаются рядом.
class ChannelScreen extends StatelessWidget {
  const ChannelScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final channel = controller.channel;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: kSidebar,
        title: Text(channel?.name ?? 'Канал'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ChannelPane(controller: controller),
    );
  }
}
