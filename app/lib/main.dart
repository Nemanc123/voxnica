import 'package:flutter/material.dart';

import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'state/app_controller.dart';
import 'theme.dart';

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
