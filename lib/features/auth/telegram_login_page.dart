import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Telegram-based login for Fogged VPN.
/// Flow: enter handle → request code → bot sends DM → enter code → authenticated
class TelegramLoginPage extends StatefulWidget {
  final Function(String uuid, String subscriptionUrl) onAuthenticated;

  const TelegramLoginPage({super.key, required this.onAuthenticated});

  @override
  State<TelegramLoginPage> createState() => _TelegramLoginPageState();
}

class _TelegramLoginPageState extends State<TelegramLoginPage> {
  final _handleController = TextEditingController();
  final _codeController = TextEditingController();
  bool _codeSent = false;
  bool _loading = false;
  String _error = '';
  String _handle = '';

  static const _apiBase = 'https://dl.fogged.net';

  Future<void> _requestCode() async {
    final handle = _handleController.text.trim().replaceAll('@', '');
    if (handle.isEmpty) {
      setState(() => _error = 'Введите ваш Telegram');
      return;
    }

    setState(() {
      _loading = true;
      _error = '';
      _handle = handle;
    });

    try {
      final resp = await http.post(
        Uri.parse('$_apiBase/auth/request'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'telegram_handle': handle}),
      );

      if (resp.statusCode == 200) {
        setState(() {
          _codeSent = true;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Ошибка. Попробуйте позже.';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Нет подключения к серверу';
        _loading = false;
      });
    }
  }

  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Введите 6-значный код');
      return;
    }

    setState(() {
      _loading = true;
      _error = '';
    });

    try {
      final resp = await http.post(
        Uri.parse('$_apiBase/auth/verify'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'telegram_handle': _handle, 'code': code}),
      );

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['ok'] == true) {
          widget.onAuthenticated(
            data['uuid'] ?? '',
            data['subscription_url'] ?? '',
          );
        } else {
          setState(() {
            _error = data['message'] ?? 'Неверный код';
            _loading = false;
          });
        }
      } else {
        setState(() {
          _error = 'Неверный или истёкший код';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Нет подключения к серверу';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'FOGGED',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 8,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _codeSent ? 'Введите код из Telegram' : 'Войти через Telegram',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 48),

                if (!_codeSent) ...[
                  TextField(
                    controller: _handleController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: '@username',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                    ),
                    onSubmitted: (_) => _requestCode(),
                  ),
                  const SizedBox(height: 16),
                  _buildButton('Получить код', _requestCode),
                ] else ...[
                  TextField(
                    controller: _codeController,
                    style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: InputDecoration(
                      hintText: '000000',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.1), fontSize: 24, letterSpacing: 8),
                      counterText: '',
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                    ),
                    onSubmitted: (_) => _verifyCode(),
                  ),
                  const SizedBox(height: 16),
                  _buildButton('Войти', _verifyCode),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => setState(() {
                      _codeSent = false;
                      _codeController.clear();
                      _error = '';
                    }),
                    child: Text('Назад', style: TextStyle(color: Colors.white.withOpacity(0.3))),
                  ),
                ],

                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error,
                    style: TextStyle(color: Colors.red.withOpacity(0.7), fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildButton(String label, VoidCallback onPressed) {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        child: _loading
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
            : Text(label),
      ),
    );
  }

  @override
  void dispose() {
    _handleController.dispose();
    _codeController.dispose();
    super.dispose();
  }
}
