import 'package:flutter/material.dart';

import 'screens/auth_screen.dart';
import 'screens/channel_screen.dart';
import 'screens/home_screen.dart';
import 'state/app_controller.dart';
import 'theme.dart';
import 'widgets/incoming_call_card.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VoxnicaApp());
}

class VoxnicaApp extends StatefulWidget {
  const VoxnicaApp({super.key});

  @override
  State<VoxnicaApp> createState() => _VoxnicaAppState();
}

class _VoxnicaAppState extends State<VoxnicaApp> {
  late final AppController _controller;
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _controller = AppController();
    _controller.init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voxnica',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorKey: _navigatorKey,
      // Входящий звонок должен быть виден на любом экране, а не только
      // на домашнем — поэтому карточка живёт над Navigator.
      builder: (context, child) {
        return ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            return Stack(
              children: [
                ?child,
                if (_controller.incomingCall != null)
                  Positioned(
                    top: 24,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: IncomingCallCard(
                        controller: _controller,
                        onAccepted: () {
                          if (MediaQuery.sizeOf(context).width >= 850) {
                            return;
                          }
                          final navigator = _navigatorKey.currentState;
                          // Если пользователь уже внутри канала, второй экран
                          // не нужен — голосовая панель появится на месте.
                          if (navigator == null || navigator.canPop()) return;
                          navigator.push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  ChannelScreen(controller: _controller),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
      home: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          switch (_controller.stage) {
            case AppStage.loading:
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            case AppStage.loggedOut:
              return AuthScreen(controller: _controller);
            case AppStage.ready:
              return HomeScreen(controller: _controller);
          }
        },
      ),
    );
  }
}
