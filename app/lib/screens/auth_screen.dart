import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../theme.dart';

/// Вход и регистрация на одном экране: переключатель режима.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();

  bool _register = false;
  String? _localError;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final username = _username.text.trim();
    final password = _password.text;

    if (username.isEmpty || password.isEmpty) {
      setState(() => _localError = 'Заполните логин и пароль');
      return;
    }

    if (_register && password.length < 10) {
      setState(() => _localError = 'Пароль должен быть не короче 10 символов');
      return;
    }

    setState(() => _localError = null);

    if (_register) {
      await widget.controller.register(
        username: username,
        password: password,
        displayName: _displayName.text.trim(),
      );
    } else {
      await widget.controller.login(username, password);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final error = _localError ?? controller.error;

    return Scaffold(
      backgroundColor: kRail,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: kBackground,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.forum, size: 48, color: kAccent),
                  const SizedBox(height: 12),
                  Text(
                    _register ? 'Создать аккаунт' : 'С возвращением',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _register
                        ? 'Ник, пароль — и можно общаться'
                        : 'Войдите, чтобы открыть серверы',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kTextMuted),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    key: const Key('auth_username'),
                    controller: _username,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: _register ? 'Ник' : 'Ник или почта',
                    ),
                  ),
                  if (_register) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('auth_display_name'),
                      controller: _displayName,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Отображаемое имя (необязательно)',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('auth_password'),
                    controller: _password,
                    obscureText: true,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(labelText: 'Пароль'),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 14),
                    Text(error, style: const TextStyle(color: kDanger)),
                  ],
                  const SizedBox(height: 20),
                  ElevatedButton(
                    key: const Key('auth_submit'),
                    onPressed: controller.busy ? null : _submit,
                    child: controller.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_register ? 'Зарегистрироваться' : 'Войти'),
                  ),
                  const SizedBox(height: 14),
                  TextButton(
                    key: const Key('auth_toggle'),
                    onPressed: controller.busy
                        ? null
                        : () {
                            setState(() {
                              _register = !_register;
                              _localError = null;
                            });
                          },
                    child: Text(
                      _register
                          ? 'Уже есть аккаунт? Войти'
                          : 'Нет аккаунта? Зарегистрироваться',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
