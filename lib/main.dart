import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

void main() => runApp(const FoggedApp());

// ── i18n ──
class L {
  static String _lang = 'en';
  static void setLang(String l) => _lang = l;
  static String get lang => _lang;

  static final _t = {
    'en': {
      'secure_vpn': 'Secure VPN',
      'enter_telegram': 'Enter your Telegram User ID',
      'userid_help': 'Find your User ID in @foggedvpnbot → Settings',
      'send_code': 'Send Code',
      'enter_code': 'Enter the code sent to your Telegram',
      'verify': 'Verify',
      'back': '← Back',
      'region': 'Region',
      'protocol': 'Protocol',
      'server': 'Server',
      'speed': 'Speed',
      'uptime': 'Uptime',
      'downloaded': 'Downloaded',
      'speed_test': 'Speed Test',
      'testing': 'Testing...',
      'connect': 'CONNECT',
      'connecting': 'CONNECTING',
      'protected': 'PROTECTED',
      'encrypted': 'All traffic encrypted',
      'tap_connect': 'Tap to connect',
      'join_channel': 'Please join our channel first:\nhttps://t.me/foggedvpn',
      'code_sent': 'Check your Telegram for the code',
      'logout': 'Logout',
      'debug': 'Debug',
      'hide': 'Hide',
      'copied': 'Copied',
      'failed': 'Failed',
      'none': 'None',
      'russia': 'Russia',
      'china': 'China',
      'direct': 'Global',
      'settings': 'Settings',
      'account': 'Account',
      'subscription': 'Subscription',
      'days_left': 'days left',
      'expired': 'Expired',
      'subscribe': 'Subscribe',
      'referrals': 'Referrals',
      'referral_link': 'Referral Link',
      'earnings': 'Earnings',
      'support': 'Support',
      'send_report': 'Send Report',
      'include_debug': 'Include debug info',
      'report_sent': 'Report sent',
      'report_hint': 'Describe your issue...',
      'run_full_test': 'Run Full Test',
      'testing_progress': 'Testing',
      'best': 'Best',
      'use_this': 'Use',
      'sni_test': 'SNI Test',
      'working': 'Working',
      'blocked': 'Blocked',
      'set_preferred': 'Set as preferred',
      'site_checker': 'Site Checker',
      'check_all': 'Check All',
      'connect_first': 'Connect first',
      'whitelist_mode': 'Whitelist Mode',
      'add_domain': 'Add domain',
      'remove': 'Remove',
      'custom_domains': 'Custom domains',
      'split_tunnel': 'Split Tunnel',
      'bypass_vpn': 'Bypass VPN',
      'domain_routing': 'Domain routing',
      'coming_soon': 'Coming soon',
      'choose_language': 'Choose your language',
      'whitelist_desc': 'VK, Yandex, Sber go direct',
    },
    'ru': {
      'secure_vpn': 'Безопасный VPN',
      'enter_telegram': 'Введите ваш Telegram User ID',
      'userid_help': 'Найдите User ID в @foggedvpnbot → Настройки',
      'send_code': 'Отправить код',
      'enter_code': 'Введите код из Telegram',
      'verify': 'Подтвердить',
      'back': '← Назад',
      'region': 'Регион',
      'protocol': 'Протокол',
      'server': 'Сервер',
      'speed': 'Скорость',
      'uptime': 'Время',
      'downloaded': 'Загружено',
      'speed_test': 'Тест скорости',
      'testing': 'Тестирование...',
      'connect': 'ПОДКЛЮЧИТЬ',
      'connecting': 'ПОДКЛЮЧЕНИЕ',
      'protected': 'ЗАЩИЩЕНО',
      'encrypted': 'Весь трафик зашифрован',
      'tap_connect': 'Нажмите для подключения',
      'join_channel': 'Подпишитесь на канал:\nhttps://t.me/foggedvpn',
      'code_sent': 'Код отправлен в Telegram',
      'logout': 'Выход',
      'debug': 'Отладка',
      'hide': 'Скрыть',
      'copied': 'Скопировано',
      'failed': 'Ошибка',
      'none': 'Нет',
      'russia': 'Россия',
      'china': 'Китай',
      'direct': 'Весь мир',
      'settings': 'Настройки',
      'account': 'Аккаунт',
      'subscription': 'Подписка',
      'days_left': 'дней',
      'expired': 'Истекла',
      'subscribe': 'Подписаться',
      'referrals': 'Рефералы',
      'referral_link': 'Реф. ссылка',
      'earnings': 'Заработок',
      'support': 'Поддержка',
      'send_report': 'Отправить',
      'include_debug': 'Добавить отладку',
      'report_sent': 'Отправлено',
      'report_hint': 'Опишите проблему...',
      'run_full_test': 'Полный тест',
      'testing_progress': 'Тестирование',
      'best': 'Лучший',
      'use_this': 'Выбрать',
      'sni_test': 'Тест SNI',
      'working': 'Работает',
      'blocked': 'Заблокирован',
      'set_preferred': 'Установить',
      'site_checker': 'Проверка сайтов',
      'check_all': 'Проверить все',
      'connect_first': 'Сначала подключитесь',
      'whitelist_mode': 'Режим белого списка',
      'add_domain': 'Добавить домен',
      'remove': 'Удалить',
      'custom_domains': 'Свои домены',
      'split_tunnel': 'Раздельный туннель',
      'bypass_vpn': 'Обойти VPN',
      'domain_routing': 'Маршрутизация доменов',
      'coming_soon': 'Скоро',
      'choose_language': 'Выберите язык',
      'whitelist_desc': 'VK, Яндекс, Сбер напрямую',
    },
    'zh': {
      'secure_vpn': '安全VPN',
      'enter_telegram': '输入您的 Telegram User ID',
      'userid_help': '在 @foggedvpnbot → 设置 中查找 User ID',
      'send_code': '发送验证码',
      'enter_code': '输入Telegram发送的验证码',
      'verify': '验证',
      'back': '← 返回',
      'region': '地区',
      'protocol': '协议',
      'server': '服务器',
      'speed': '速度',
      'uptime': '运行时间',
      'downloaded': '已下载',
      'speed_test': '速度测试',
      'testing': '测试中...',
      'connect': '连接',
      'connecting': '连接中',
      'protected': '已保护',
      'encrypted': '所有流量已加密',
      'tap_connect': '点击连接',
      'join_channel': '请先加入频道:\nhttps://t.me/foggedvpn',
      'code_sent': '验证码已发送到Telegram',
      'logout': '退出',
      'debug': '调试',
      'hide': '隐藏',
      'copied': '已复制',
      'failed': '失败',
      'none': '无',
      'russia': '俄罗斯',
      'china': '中国',
      'direct': '全球',
      'settings': '设置',
      'account': '账户',
      'subscription': '订阅',
      'days_left': '天',
      'expired': '已过期',
      'subscribe': '订阅',
      'referrals': '推荐',
      'referral_link': '推荐链接',
      'earnings': '收入',
      'support': '支持',
      'send_report': '发送',
      'include_debug': '包含调试信息',
      'report_sent': '已发送',
      'report_hint': '描述您的问题...',
      'run_full_test': '完整测试',
      'testing_progress': '测试中',
      'best': '最佳',
      'use_this': '使用',
      'sni_test': 'SNI测试',
      'working': '正常',
      'blocked': '已封锁',
      'set_preferred': '设为首选',
      'site_checker': '网站检查',
      'check_all': '检查全部',
      'connect_first': '请先连接',
      'whitelist_mode': '白名单模式',
      'add_domain': '添加域名',
      'remove': '删除',
      'custom_domains': '自定义域名',
      'split_tunnel': '分流',
      'bypass_vpn': '绕过VPN',
      'domain_routing': '域名路由',
      'coming_soon': '即将推出',
      'choose_language': '选择语言',
      'whitelist_desc': 'VK、Yandex、Sber直连',
    },
  };

  static String tr(String key) => _t[_lang]?[key] ?? _t['en']?[key] ?? key;
}

class FoggedApp extends StatelessWidget {
  const FoggedApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Fogged', debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: Colors.black, useMaterial3: true),
    home: const HomeScreen(),
  );
}

// ── Parsed server from subscription ──
class VpnServer {
  final String protocol; // 'vless', 'hysteria2', 'orcax'
  final String name;
  final String addr; // ip:port
  final Map<String, String> params; // pbk, sid, sni, flow, obfs, etc.
  VpnServer(this.protocol, this.name, this.addr, this.params);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  // Auth
  bool _langPicked = true; // assume true, set false if no pref saved
  bool _loggedIn = false;
  String _uuid = '';
  String _telegramHandle = '';
  bool _authLoading = false;
  bool _codeRequested = false;
  int _codeTimer = 0; // seconds remaining
  final _handleCtl = TextEditingController();
  final _codeCtl = TextEditingController();

  // Connection
  bool _connected = false;
  bool _connecting = false;
  String _protocol = 'VLESS+Reality';
  String _server = '';
  String _uptime = '--';
  String _downloaded = '0 B';
  Process? _proxyProcess;
  late AnimationController _pulseController;

  // Platform channel for tray/menu bar
  static const _trayChannel = MethodChannel('com.fogged.vpn/tray');

  // Servers from subscription
  List<VpnServer> _servers = [];

  // Speed test
  bool _testing = false;
  String _testResult = '';

  // Full speed test suite
  bool _fullTesting = false;
  int _fullTestProgress = 0;
  int _fullTestTotal = 0;
  List<Map<String, dynamic>> _fullTestResults = [];

  // Site checker
  bool _checkingSites = false;
  List<Map<String, dynamic>> _siteResults = [];

  // SNI test
  bool _testingSni = false;
  List<Map<String, dynamic>> _sniResults = [];

  // Split tunnel custom domains
  List<String> _splitDomains = [];

  // Debug
  final List<String> _debugLogs = [];
  final _debugScroll = ScrollController();

  // Whitelist mode (Russian whitelisted domains bypass VPN)
  bool _whitelistMode = false;

  // Account info (from /account/{uuid})
  String _accountNumber = '';
  String _subStatus = '';
  String _subEndsAt = '';
  String _referralCode = '';
  double _referralEarnings = 0.0;
  int _totalReferrals = 0;
  String _userRole = 'user'; // admin, supermod, user

  static const _protocols = ['VLESS+Reality', 'Hysteria2', 'OrcaX Pro Max', 'OrcaX VLESS'];
  static const _apiBase = 'https://dl.fogged.net';
  String _appVersion = '1.3.0'; // Updated from PackageInfo at runtime

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _trayChannel.setMethodCallHandler((call) async {
      if (call.method == 'isConnected') return _connected;
      return null;
    });
    // Load version from package info (single source of truth: pubspec.yaml)
    PackageInfo.fromPlatform().then((info) { if (mounted) setState(() => _appVersion = info.version); });
    _loadAuth();
    // Check for updates on every app start (all platforms)
    Future.delayed(const Duration(seconds: 2), _checkForUpdate);
  }

  @override
  void dispose() { _pulseController.dispose(); _disconnect(); super.dispose(); }

  // ── Auth ──

  Future<void> _loadAuth() async {
    final prefs = await SharedPreferences.getInstance();
    final uuid = prefs.getString('uuid') ?? '';
    final handle = prefs.getString('telegram_handle') ?? '';
    final lang = prefs.getString('lang');
    if (lang == null) {
      // First launch — show language picker
      setState(() => _langPicked = false);
      return;
    }
    L.setLang(['ru', 'zh'].contains(lang) ? lang : 'en');
    _whitelistMode = prefs.getBool('whitelist_mode') ?? false;
    _splitDomains = prefs.getStringList('split_domains') ?? [];
    // Restore last used protocol/server/mode
    final savedProtocol = prefs.getString('last_protocol');
    final savedServer = prefs.getString('last_server');
    final savedMode = prefs.getString('last_mode');
    if (savedMode != null) _mode = savedMode;
    if (savedProtocol != null && _protocols.contains(savedProtocol)) _protocol = savedProtocol;
    if (uuid.isNotEmpty) {
      setState(() { _loggedIn = true; _uuid = uuid; _telegramHandle = handle; });
      await _fetchSubscription();
      // Restore saved server after subscription loads
      if (savedServer != null && _filteredServers.any((s) => s.name == savedServer)) {
        _server = savedServer;
      }
      await _fetchAccountInfo();
      // Auto-connect if user was connected last session or has auto-start enabled
      final wasConnected = prefs.getBool('was_connected') ?? false;
      final autoStart = prefs.getBool('auto_start') ?? false;
      if ((wasConnected || autoStart) && _filteredServers.isNotEmpty) {
        setState(() => _connecting = true);
        _startProxy();
      }
    }
  }

  Future<void> _fetchAccountInfo() async {
    if (_uuid.isEmpty) return;
    try {
      final resp = await http.get(Uri.parse('$_apiBase/account/$_uuid'));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        setState(() {
          _accountNumber = j['account_number'] ?? '';
          _subStatus = j['subscription_status'] ?? '';
          _subEndsAt = j['subscription_ends_at'] ?? '';
          _referralCode = j['referral_code'] ?? '';
          _referralEarnings = (j['referral_earnings_usd'] ?? 0).toDouble();
          _totalReferrals = (j['total_referrals'] ?? 0).toInt();
          _userRole = j['role'] ?? 'user';
        });
        // Load cloud-synced app settings if present
        final settings = j['app_settings'];
        if (settings is Map) {
          final prefs = await SharedPreferences.getInstance();
          if (settings['whitelist_mode'] != null && !prefs.containsKey('whitelist_mode')) {
            _whitelistMode = settings['whitelist_mode'] == true;
          }
          if (settings['split_domains'] is List && !prefs.containsKey('split_domains')) {
            _splitDomains = (settings['split_domains'] as List).cast<String>();
          }
          if (settings['protocol'] is String && !prefs.containsKey('last_protocol')) {
            _protocol = settings['protocol'];
          }
          if (settings['mode'] is String && !prefs.containsKey('last_mode')) {
            _mode = settings['mode'];
          }
        }
      } else {
        _addLog('account fetch: ${resp.statusCode}');
      }
    } catch (e) {
      _addLog('account fetch error: $e');
    }
  }

  /// Sync app settings to server (cloud backup)
  Future<void> _syncSettings() async {
    if (_uuid.isEmpty) return;
    try {
      await http.post(Uri.parse('$_apiBase/account/$_uuid/settings'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'whitelist_mode': _whitelistMode,
          'split_domains': _splitDomains,
          'protocol': _protocol,
          'server': _server,
          'mode': _mode,
        }));
    } catch (_) {}
  }

  Future<void> _checkForUpdate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastDismissed = prefs.getInt('update_dismissed_at') ?? 0;
      final skippedVersion = prefs.getString('update_skipped_version') ?? '';
      final installedVersion = prefs.getString('update_installed_version') ?? '';
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastDismissed < 86400000) return;

      final resp = await http.get(Uri.parse('$_apiBase/version'));
      if (resp.statusCode != 200) return;
      final j = jsonDecode(resp.body);
      final latest = j['version'] as String? ?? _appVersion;
      final notes = j['notes'] as String? ?? 'Improvements and bug fixes.';
      if (latest == _appVersion || latest == skippedVersion || latest == installedVersion) return;

      final downloadUrl = Platform.isMacOS ? (j['download_macos'] as String? ?? '')
          : Platform.isWindows ? (j['download_windows'] as String? ?? '')
          : (j['download_android'] as String? ?? '');
      if (downloadUrl.isEmpty || !mounted) return;

      showDialog(context: context, barrierDismissible: false, builder: (ctx) =>
        _UpdateDialog(version: latest, notes: notes, downloadUrl: downloadUrl, onSkip: () async {
          Navigator.pop(ctx);
          final p = await SharedPreferences.getInstance();
          await p.setString('update_skipped_version', latest);
        }, onLater: () async {
          Navigator.pop(ctx);
          final p = await SharedPreferences.getInstance();
          await p.setInt('update_dismissed_at', DateTime.now().millisecondsSinceEpoch);
        }),
      );
    } catch (_) {}
  }

  String get _daysLeft {
    if (_subEndsAt.isEmpty) return '?';
    try {
      final end = DateTime.parse(_subEndsAt);
      final days = end.difference(DateTime.now()).inDays;
      return days > 0 ? '$days' : '0';
    } catch (_) { return '?'; }
  }

  Future<void> _setLang(String lang) async {
    L.setLang(lang);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lang', lang);
    setState(() {});
  }

  Future<void> _requestCode() async {
    final handle = _handleCtl.text.trim().replaceAll('@', '');
    if (handle.isEmpty) return;
    setState(() => _authLoading = true);
    try {
      final resp = await http.post(Uri.parse('$_apiBase/auth/request'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'telegram_handle': handle}));
      final j = jsonDecode(resp.body);
      if (j['ok'] == true) {
        setState(() { _codeRequested = true; _telegramHandle = handle; _codeTimer = 300; });
        // Start countdown timer (5 min = 300s)
        Future.doWhile(() async {
          await Future.delayed(const Duration(seconds: 1));
          if (!mounted || _codeTimer <= 0) return false;
          setState(() => _codeTimer--);
          return _codeTimer > 0;
        });
        _showMsg('Check your Telegram for the code');
      } else {
        _showError(j['message'] ?? 'Request failed');
      }
    } catch (e) { _showError('$e'); }
    setState(() => _authLoading = false);
  }

  Future<void> _verifyCode() async {
    final code = _codeCtl.text.trim();
    if (code.isEmpty) return;
    setState(() => _authLoading = true);
    try {
      final resp = await http.post(Uri.parse('$_apiBase/auth/verify'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'telegram_handle': _telegramHandle, 'code': code}));
      final j = jsonDecode(resp.body);
      if (j['ok'] == true && j['uuid'] != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('uuid', j['uuid']);
        await prefs.setString('telegram_handle', _telegramHandle);
        _uuid = j['uuid'];
        await _fetchSubscription();
        setState(() { _loggedIn = true; });
      } else {
        _showError(j['message'] ?? 'Invalid code');
      }
    } catch (e) { _showError('$e'); }
    setState(() => _authLoading = false);
  }

  Future<void> _logout() async {
    await _disconnect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('uuid');
    await prefs.remove('telegram_handle');
    setState(() { _loggedIn = false; _uuid = ''; _servers = []; _codeRequested = false; });
  }

  // ── Subscription parsing ──

  String _mode = 'russia'; // russia, china, direct
  static const _modes = ['russia', 'china', 'direct'];
  // ignore: unused_field
  static const _modeLabels = {'russia': 'Russia', 'china': 'China', 'direct': 'Global'};

  Future<void> _fetchSubscription() async {
    if (_uuid.isEmpty) return;
    try {
      final servers = <VpnServer>[];

      // 1. Fetch VLESS/CDN from subs endpoint
      final resp = await http.get(Uri.parse('$_apiBase/subs/$_uuid?mode=$_mode'));
      if (resp.statusCode == 200) {
        final decoded = utf8.decode(base64.decode(resp.body.trim()));
        for (final line in decoded.split('\n').where((l) => l.isNotEmpty)) {
          final s = _parseLine(line);
          if (s != null) servers.add(s);
        }
      }

      // 2. Fetch HY2 from singbox endpoint
      final sbResp = await http.get(Uri.parse('$_apiBase/singbox/$_uuid?mode=$_mode'));
      if (sbResp.statusCode == 200) {
        try {
          final j = jsonDecode(sbResp.body);
          final outbounds = j['outbounds'] as List? ?? [];
          for (final ob in outbounds) {
            if (ob['type'] == 'hysteria2') {
              final name = ob['tag'] as String? ?? 'HY2';
              final ip = ob['server'] as String? ?? '';
              final port = ob['server_port'] as int? ?? 20000;
              final obfs = ob['obfs']?['password'] as String? ?? '';
              servers.add(VpnServer('hysteria2', name, '$ip:$port', {'obfs-password': obfs}));
            }
          }
        } catch (_) {}
      }

      // OrcaX servers come from subscription now — no hardcoded duplicates

      setState(() { _servers = servers; if (servers.isNotEmpty) _server = _filteredServers.isNotEmpty ? _filteredServers.first.name : servers.first.name; });
    } catch (e) { debugPrint('Sub fetch: $e'); }
  }

  VpnServer? _parseLine(String line) {
    try {
      final uri = Uri.parse(line);
      if (uri.scheme == 'vless') {
        final name = Uri.decodeComponent(uri.fragment);
        final params = uri.queryParameters;
        return VpnServer('vless', name, '${uri.host}:${uri.port}', params);
      } else if (uri.scheme == 'hysteria2') {
        final name = Uri.decodeComponent(uri.fragment);
        return VpnServer('hysteria2', name, '${uri.host}:${uri.port}', uri.queryParameters);
      } else if (uri.scheme == 'orcax') {
        final name = Uri.decodeComponent(uri.fragment);
        return VpnServer('orcax', name, '${uri.host}:${uri.port}', uri.queryParameters);
      }
    } catch (_) {}
    return null;
  }

  List<VpnServer> get _filteredServers {
    // Production protocols → production servers from subscription
    if (_protocol == 'VLESS+Reality') return _servers.where((s) => s.protocol == 'vless').toList();
    if (_protocol == 'Hysteria2') return _servers.where((s) => s.protocol == 'hysteria2').toList();
    // All 3 OrcaX protocols → OrcaX test server only
    if (_protocol.startsWith('OrcaX')) return _servers.where((s) => s.protocol == 'orcax').toList();
    return _servers.where((s) => s.protocol == 'vless').toList();
  }

  // ── Connection ──

  Future<void> _disconnect() async {
    if (Platform.isAndroid) {
      await _androidVpn.invokeMethod('stopVpn');
    } else {
      _proxyProcess?.kill();
      _proxyProcess = null;
      await Process.run('bash', ['-c', 'lsof -ti :1080 | xargs kill -9 2>/dev/null']);
      await _setSystemProxy(false);
    }
    await Future.delayed(const Duration(milliseconds: 500)); // Wait for port release
    if (mounted) setState(() { _connected = false; _connecting = false; _uptime = '--'; _downloaded = '0 B'; }); _trayChannel.invokeMethod('setConnected', false); SharedPreferences.getInstance().then((p) => p.setBool('was_connected', false));
  }

  Future<void> _toggleConnection() async {
    if (_connected || _connecting) { await _disconnect(); } else { setState(() => _connecting = true); await _startProxy(); }
  }

  // Android VPN channel
  static const _androidVpn = MethodChannel('com.fogged.vpn/android');

  Future<void> _startProxy() async {
    try {
      final srv = _filteredServers.firstWhere((s) => s.name == _server, orElse: () => _filteredServers.first);
      final proto = srv.protocol;

      // Android: use native VpnService instead of Process.run
      if (Platform.isAndroid) {
        final result = await _androidVpn.invokeMethod('startVpn', {
          'server': srv.addr,
          'uuid': _uuid,
          'protocol': _protocol == 'OrcaX Pro Max' ? 'quic' : 'tcp',
          'pubkey': srv.params['pubkey'] ?? '',
        });
        if (result == true) {
          setState(() { _connected = true; _connecting = false; _uptime = '0:00'; }); _trayChannel.invokeMethod('setConnected', true); SharedPreferences.getInstance().then((p) => p.setBool('was_connected', true));
          _startUptimeTimer();
          _addLog('Android VPN connected');
        } else {
          setState(() => _connecting = false);
          _showError('VPN permission denied');
        }
        return;
      }
      String binary;
      List<String> args;

      if (proto == 'orcax') {
        binary = await _findBinary('orcax-connect') ?? '';
        if (binary.isEmpty) { _showError('orcax-connect not found'); setState(() => _connecting = false); return; }
        // Pro Max = QUIC on port 9444, VLESS/HY2 = TCP on tcp_port (9446)
        // Pro Max + OrcaX HY2 → QUIC port 9444, OrcaX VLESS → TCP port 9446
        final useQuic = _protocol == 'OrcaX Pro Max' || _protocol == 'OrcaX Hysteria2';
        final serverAddr = useQuic ? srv.addr : srv.addr.replaceAll(':9444', ':${srv.params['tcp_port'] ?? '9446'}');
        args = ['--server', serverAddr, '--socks', '127.0.0.1:1080', '--uuid', _uuid];
        // Pro Max and OrcaX HY2 both use QUIC transport
        if (_protocol == 'OrcaX Pro Max' || _protocol == 'OrcaX Hysteria2') { args.addAll(['--protocol', 'quic']); }
      } else if (proto == 'vless') {
        binary = await _findBinary('xray') ?? '';
        if (binary.isEmpty) { _showError('xray binary not found in orcax/bin/'); setState(() => _connecting = false); return; }
        final config = _generateXrayConfig(srv, _uuid);
        final configPath = '/tmp/fogged-vless.json';
        await File(configPath).writeAsString(config);
        args = ['run', '-config', configPath];
      } else if (proto == 'hysteria2') {
        binary = await _findBinary('hysteria') ?? '';
        if (binary.isEmpty) { _showError('hysteria binary not found in orcax/bin/'); setState(() => _connecting = false); return; }
        final config = _generateHy2Config(srv, _uuid);
        final configPath = '/tmp/fogged-hy2.yaml';
        await File(configPath).writeAsString(config);
        args = ['client', '-c', configPath];
      } else {
        _showError('Unknown protocol: $proto'); setState(() => _connecting = false); return;
      }

      _addLog('launching $proto → ${srv.name} (${srv.addr})');
      _proxyProcess = await Process.start(binary, args);

      _proxyProcess!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
        // OrcaX emits JSON, Xray/Hysteria emit plain text
        if (proto == 'orcax') {
          _handleOrcaxOutput(line);
        } else {
          _addLog(line);
          // Xray/Hysteria: SOCKS5 is ready after a brief startup
          if (!_connected && (line.contains('started') || line.contains('listening') || line.contains('TCP'))) {
            await Future.delayed(const Duration(milliseconds: 500));
            await _setSystemProxy(true);
            setState(() { _connected = true; _connecting = false; _uptime = '0:00'; }); _trayChannel.invokeMethod('setConnected', true); SharedPreferences.getInstance().then((p) => p.setBool('was_connected', true));
            _startUptimeTimer();
          }
        }
      });

      _proxyProcess!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        _addLog(line);
        // Xray/Hysteria log to stderr
        if (!_connected && (line.contains('started') || line.contains('listening') || line.contains('TCP') || line.contains('connected'))) {
          _setSystemProxy(true);
          setState(() { _connected = true; _connecting = false; _uptime = '0:00'; }); _trayChannel.invokeMethod('setConnected', true); SharedPreferences.getInstance().then((p) => p.setBool('was_connected', true));
          _startUptimeTimer();
        }
      });

      // For Xray/HY2: they don't emit "connected" — assume ready after 2s
      if (proto != 'orcax') {
        Future.delayed(const Duration(seconds: 2), () async {
          if (_connecting && mounted) {
            await _setSystemProxy(true);
            setState(() { _connected = true; _connecting = false; _uptime = '0:00'; }); _trayChannel.invokeMethod('setConnected', true); SharedPreferences.getInstance().then((p) => p.setBool('was_connected', true));
            _startUptimeTimer();
          }
        });
      }

      _proxyProcess!.exitCode.then((_) async {
        if (_connected && mounted) {
          _addLog('process exited — reconnecting');
          setState(() { _connecting = true; _connected = false; });
          await _setSystemProxy(false);
          await Future.delayed(const Duration(seconds: 2));
          if (mounted && _connecting) await _startProxy();
        } else {
          await _setSystemProxy(false);
          if (mounted) setState(() { _connected = false; _connecting = false; });
        }
      });
    } catch (e) { setState(() => _connecting = false); _showError('$e'); }
  }

  void _handleOrcaxOutput(String line) {
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      final status = json['status'] as String?;
      if (status == 'connected') {
        _setSystemProxy(true);
        setState(() { _connected = true; _connecting = false; _uptime = '0:00'; }); _trayChannel.invokeMethod('setConnected', true); SharedPreferences.getInstance().then((p) => p.setBool('was_connected', true));
        _startUptimeTimer();
      } else if (status == 'log') {
        _addLog(json['msg'] as String? ?? '');
      } else if (status == 'error') {
        setState(() => _connecting = false);
        _showError(json['detail'] as String? ?? 'Unknown error');
      } else if (status == 'stats') {
        final down = json['down'] as int? ?? 0;
        if (mounted) setState(() { _downloaded = _fmtBytes(down); });
      }
    } catch (_) { _addLog(line); }
  }

  void _addLog(String msg) {
    if (msg.trim().isEmpty) return;
    setState(() {
      _debugLogs.add(msg);
      if (_debugLogs.length > 300) _debugLogs.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_debugScroll.hasClients) _debugScroll.jumpTo(_debugScroll.position.maxScrollExtent);
    });
  }

  // ── Config generators ──

  String _generateXrayConfig(VpnServer srv, String uuid) {
    final parts = srv.addr.split(':');
    final ip = parts[0];
    final port = parts.length > 1 ? parts[1] : '8443';
    final pbk = srv.params['pbk'] ?? '';
    final sid = srv.params['sid'] ?? '';
    final sni = srv.params['sni'] ?? 'cdn.jsdelivr.net';
    final flow = srv.params['flow'] ?? 'xtls-rprx-vision';
    final fp = srv.params['fp'] ?? 'random';
    return jsonEncode({
      "log": {"loglevel": "warning"},
      "inbounds": [{"tag": "socks", "protocol": "socks", "listen": "127.0.0.1", "port": 1080,
        "settings": {"auth": "noauth", "udp": true}}],
      "outbounds": [{"tag": "proxy", "protocol": "vless", "settings": {
        "vnext": [{"address": ip, "port": int.tryParse(port) ?? 8443,
          "users": [{"id": uuid, "encryption": "none", "flow": flow}]}]},
        "streamSettings": {"network": "tcp", "security": "reality",
          "realitySettings": {"serverName": sni, "fingerprint": fp,
            "publicKey": pbk, "shortId": sid}}}]
    });
  }

  String _generateHy2Config(VpnServer srv, String uuid) {
    final parts = srv.addr.split(':');
    final ip = parts[0];
    final port = parts.length > 1 ? parts[1] : '20000-50000';
    final obfs = srv.params['obfs-password'] ?? srv.params['obfs'] ?? 'fogged_hy2_sal_2026';
    return '''
server: $ip:$port
auth: $uuid
obfs:
  type: salamander
  salamander:
    password: $obfs
socks5:
  listen: 127.0.0.1:1080
tls:
  insecure: true
''';
  }

  // ── Binary finder ──

  Future<String?> _findBinary(String name) async {
    final ext = Platform.isWindows ? '.exe' : '';
    final binName = '$name$ext';
    final paths = Platform.isWindows ? [
      '${Platform.environment['LOCALAPPDATA']}\\Fogged\\bin\\$binName',
      '${Directory.current.path}\\bin\\$binName',
      'C:\\Program Files\\Fogged\\$binName',
    ] : [
      '/Users/anon/CascadeProjects/Work/orcax/bin/$binName',
      '/Users/anon/CascadeProjects/Work/orcax/target/release/$binName',
      '/Users/anon/CascadeProjects/Work/orcax/target/debug/$binName',
      '/usr/local/bin/$binName',
    ];
    for (final p in paths) { if (await File(p).exists()) return p; }
    return null;
  }

  // ── System proxy ──

  /// Russian government whitelisted domains — bypass VPN when whitelist mode enabled
  static const _whitelistedDomains = [
    'vk.com', 'vk.me', 'vkontakte.ru', 'vk.cc',
    'ok.ru', 'odnoklassniki.ru',
    'mail.ru', 'list.ru', 'inbox.ru', 'bk.ru',
    'yandex.ru', 'yandex.com', 'ya.ru',
    'sberbank.ru', 'online.sberbank.ru', 'sber.ru',
    'tinkoff.ru', 'alfabank.ru', 'vtb.ru',
    'gosuslugi.ru', 'mos.ru', 'gov.ru', 'kremlin.ru',
    'ria.ru', 'tass.ru', 'rt.com',
    'wildberries.ru', 'ozon.ru', 'avito.ru',
    'rutube.ru', 'dzen.ru',
    'megafon.ru', 'mts.ru', 'beeline.ru', 'tele2.ru',
    'gazprom.ru', 'rosneft.ru',
  ];

  Future<void> _setSystemProxy(bool enable) async {
    try {
      if (Platform.isMacOS) {
        final r = await Process.run('networksetup', ['-listallnetworkservices']);
        final svcs = (r.stdout as String).split('\n').where((s) => s.contains('Wi-Fi') || s.contains('Ethernet')).toList();
        for (final svc in svcs) {
          final name = svc.trim();
          if (enable) {
            if (_whitelistMode || _splitDomains.isNotEmpty) {
              final pac = _generatePacFile();
              final pacPath = '/tmp/fogged-proxy.pac';
              await File(pacPath).writeAsString(pac);
              await Process.run('networksetup', ['-setautoproxyurl', name, 'file:///$pacPath']);
              await Process.run('networksetup', ['-setautoproxystate', name, 'on']);
              await Process.run('networksetup', ['-setsocksfirewallproxystate', name, 'off']);
            } else {
              await Process.run('networksetup', ['-setautoproxystate', name, 'off']);
              await Process.run('networksetup', ['-setsocksfirewallproxy', name, '127.0.0.1', '1080']);
              await Process.run('networksetup', ['-setsocksfirewallproxystate', name, 'on']);
            }
          } else {
            await Process.run('networksetup', ['-setsocksfirewallproxystate', name, 'off']);
            await Process.run('networksetup', ['-setautoproxystate', name, 'off']);
          }
        }
      } else if (Platform.isWindows) {
        if (enable) {
          if (_whitelistMode || _splitDomains.isNotEmpty) {
            final pac = _generatePacFile();
            final pacPath = '${Platform.environment['TEMP']}\\fogged-proxy.pac';
            await File(pacPath).writeAsString(pac);
            await Process.run('reg', ['add', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings', '/v', 'AutoConfigURL', '/t', 'REG_SZ', '/d', 'file:///$pacPath', '/f']);
            await Process.run('reg', ['add', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings', '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
          } else {
            await Process.run('reg', ['add', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings', '/v', 'ProxyServer', '/t', 'REG_SZ', '/d', 'socks=127.0.0.1:1080', '/f']);
            await Process.run('reg', ['add', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings', '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f']);
          }
        } else {
          await Process.run('reg', ['add', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings', '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
          await Process.run('reg', ['delete', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings', '/v', 'AutoConfigURL', '/f']);
        }
      } else if (Platform.isLinux) {
        if (enable) {
          await Process.run('gsettings', ['set', 'org.gnome.system.proxy', 'mode', 'manual']);
          await Process.run('gsettings', ['set', 'org.gnome.system.proxy.socks', 'host', '127.0.0.1']);
          await Process.run('gsettings', ['set', 'org.gnome.system.proxy.socks', 'port', '1080']);
        } else {
          await Process.run('gsettings', ['set', 'org.gnome.system.proxy', 'mode', 'none']);
        }
      }
    } catch (_) {}
  }

  String _generatePacFile() {
    final allBypass = [..._whitelistedDomains, ..._splitDomains];
    final conditions = allBypass.map((d) =>
      '    if (dnsDomainIs(host, "$d")) return "DIRECT";'
    ).join('\n');
    return '''function FindProxyForURL(url, host) {
    // Russian government whitelisted domains — go direct
$conditions

    // Everything else through VPN
    return "SOCKS5 127.0.0.1:1080; SOCKS 127.0.0.1:1080; DIRECT";
}''';
  }

  // ── Speed test ──

  Future<void> _runSpeedTest() async {
    if (!_connected || _testing) return;
    setState(() { _testing = true; _testResult = 'Testing...'; });
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        // Mobile: use Dart HTTP directly (VPN routes traffic)
        final start = DateTime.now();
        final resp = await http.get(Uri.parse('https://hel1-speed.hetzner.com/100MB.bin'),
          headers: {'Range': 'bytes=0-5242879'}).timeout(const Duration(seconds: 30));
        final elapsed = DateTime.now().difference(start);
        final bytes = resp.bodyBytes.length;
        final mbps = (bytes * 8) / (elapsed.inMilliseconds / 1000) / 1000000;
        final latencyMs = elapsed.inMilliseconds > 0 ? (elapsed.inMilliseconds * 0.1).round() : 0;
        if (mounted) setState(() { _testing = false; _testResult = '${mbps.toStringAsFixed(1)} Mbps | ${latencyMs}ms | ${_fmtBytes(bytes)} in ${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s'; });
      } else {
      // Desktop: use curl through SOCKS proxy
      final result = await Process.run('curl', [
        '-x', 'socks5h://127.0.0.1:1080', '-so', '/dev/null',
        '-w', '%{speed_download}|%{size_download}|%{time_total}|%{time_starttransfer}',
        '-r', '0-5242879', 'https://hel1-speed.hetzner.com/100MB.bin', '--max-time', '30',
      ]);
      final parts = result.stdout.toString().split('|');
      if (parts.length >= 4) {
        final speedBps = double.tryParse(parts[0]) ?? 0;
        final bytes = int.tryParse(parts[1]) ?? 0;
        final totalTime = double.tryParse(parts[2]) ?? 0;
        final ttfb = double.tryParse(parts[3]) ?? 0;
        final mbps = (speedBps * 8) / 1000000;
        final latencyMs = (ttfb * 1000).round();
        if (mounted) setState(() { _testing = false; _testResult = '${mbps.toStringAsFixed(1)} Mbps | ${latencyMs}ms | ${_fmtBytes(bytes)} in ${totalTime.toStringAsFixed(1)}s'; });
      } else {
        if (mounted) setState(() { _testing = false; _testResult = L.tr('failed'); });
      }
      } // close desktop else
    } catch (e) { if (mounted) setState(() { _testing = false; _testResult = L.tr('failed'); }); _addLog('speed test: $e'); }
  }

  // ── Helpers ──

  void _showError(String msg) {
    if (!mounted) return;
    _addLog('ERROR: $msg');
    // Hide technical details from regular users
    final userMsg = (_userRole == 'admin' || _userRole == 'supermod') ? msg
        : msg.contains('ProcessException') ? L.tr('failed')
        : msg.contains('curl') ? L.tr('failed')
        : msg.contains('No such file') ? L.tr('failed')
        : msg.length > 80 ? '${msg.substring(0, 80)}...' : msg;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(userMsg), backgroundColor: Colors.red.shade900, duration: const Duration(seconds: 3)));
  }
  void _showMsg(String msg) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3))); }
  String _fmtBytes(int b) { if (b < 1024) return '$b B'; if (b < 1048576) return '${(b / 1024).toStringAsFixed(0)} KB'; if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB'; return '${(b / 1073741824).toStringAsFixed(2)} GB'; }

  void _startUptimeTimer() {
    final start = DateTime.now();
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || !_connected) return false;
      final e = DateTime.now().difference(start);
      setState(() => _uptime = '${e.inMinutes}:${(e.inSeconds % 60).toString().padLeft(2, '0')}');
      return _connected;
    });
  }

  // ── Sidebar nav state ──
  int _navIndex = 0; // 0=home, 1=settings

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    if (!_langPicked) return _languagePickerScreen();
    if (!_loggedIn) return _authScreen();
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Row(children: [
        // Left sidebar
        _sidebar(),
        // Main content
        Expanded(child: switch (_navIndex) {
          0 => _homePanel(),
          1 => _settingsPanel(),
          2 => _speedPanel(),
          3 => _debugPanel(),
          4 => _siteCheckerPanel(),
          _ => _homePanel(),
        }),
      ]),
    );
  }

  Widget _sidebar() {
    return Container(
      width: 56, color: const Color(0xFF111111),
      child: Column(children: [
        const SizedBox(height: 20),
        // Logo
        Padding(padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(children: [
            Image.asset('assets/logo.png', width: 28, height: 28, opacity: AlwaysStoppedAnimation(_connected ? 1.0 : 0.7)),
            const SizedBox(height: 4),
            Text('v$_appVersion', style: TextStyle(fontSize: 9, color: Colors.white.withValues(alpha: 0.3))),
          ])),
        const SizedBox(height: 8),
        _navIcon(Icons.shield, 0),
        _navIcon(Icons.speed, 2),
        _navIcon(Icons.public, 4),  // site checker
        _navIcon(Icons.settings, 1),
        const Spacer(),
        if (_userRole == 'admin' || _userRole == 'supermod')
          _navIcon(Icons.terminal, 3),
        // Sub days
        if (_subEndsAt.isNotEmpty) Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text('${_daysLeft}d', style: TextStyle(fontSize: 9,
            color: int.tryParse(_daysLeft) != null && int.parse(_daysLeft) > 3 ? Colors.white24 : Colors.red.shade300)),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _navIcon(IconData icon, int idx) {
    final active = _navIndex == idx;
    return GestureDetector(
      onTap: () => setState(() => _navIndex = idx),
      child: Container(
        width: 56, height: 44,
        decoration: BoxDecoration(border: Border(left: BorderSide(color: active ? Colors.white : Colors.transparent, width: 2))),
        child: Icon(icon, size: 18, color: active ? Colors.white : Colors.white24),
      ),
    );
  }

  Widget _homePanel() {
    final filtered = _filteredServers;
    final accent = _connected ? Colors.white : _connecting ? Colors.white54 : Colors.white30;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        border: Border(left: BorderSide(color: Colors.white.withValues(alpha: 0.05))),
      ),
      child: Column(children: [
        // Top status bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(children: [
            Text(_connected ? L.tr('protected') : _connecting ? L.tr('connecting') : L.tr('connect'),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 2, color: accent)),
            const Spacer(),
            if (_connected) Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.green.shade400)),
            if (_connecting) SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white.withValues(alpha: 0.5))),
          ]),
        ),

        Expanded(child: SingleChildScrollView(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const SizedBox(height: 20),

            // Connect button
            GestureDetector(onTap: _toggleConnection, child: AnimatedBuilder(animation: _pulseController, builder: (_, __) {
              final op = _connecting ? (_pulseController.value * 0.5 + 0.3) : _connected ? 1.0 : 0.12;
              return Container(width: 130, height: 130, decoration: BoxDecoration(shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: op), width: 1.5),
                boxShadow: _connected ? [BoxShadow(color: Colors.white.withValues(alpha: 0.05), blurRadius: 30)] : []),
                child: Center(child: Icon(_connected ? Icons.lock : Icons.power_settings_new, size: 32, color: accent)));
            })),
            const SizedBox(height: 16),
            Text(_connected ? L.tr('encrypted') : L.tr('tap_connect'),
              style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: _connected ? 0.4 : 0.15))),
            const SizedBox(height: 24),

            // Stats row (when connected)
            if (_connected) ...[
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _statChip(L.tr('uptime'), _uptime),
                _statChip(L.tr('downloaded'), _downloaded),
              ]),
              const SizedBox(height: 20),
            ],

            // Server selector card
            Container(
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08))),
              child: Column(children: [
                _selectRow(L.tr('region'), L.tr(_mode), () =>
                  _showSheet(L.tr('region'), _modes.map((m) => (m, L.tr(m))).toList(), _mode, (v) {
                    final autoLang = {'russia': 'ru', 'china': 'zh', 'direct': 'en'}[v] ?? 'en';
                    _setLang(autoLang);
                    setState(() { _mode = v; _testResult = ''; });
                    SharedPreferences.getInstance().then((p) => p.setString('last_mode', v));
                    _syncSettings();
                    _fetchSubscription().then((_) {
                      final f = _filteredServers;
                      if (f.isNotEmpty) setState(() => _server = f.first.name);
                      if (_connected) _disconnect().then((_) { setState(() => _connecting = true); _startProxy(); });
                    });
                  })),
                _thinDiv(),
                _selectRow(L.tr('protocol'), _protocol, () =>
                  _showSheet(L.tr('protocol'), _protocols.map((p) => (p, p)).toList(), _protocol, (v) {
                    setState(() { _protocol = v; _testResult = ''; final f = _filteredServers; if (f.isNotEmpty) _server = f.first.name; });
                    SharedPreferences.getInstance().then((p) { p.setString('last_protocol', v); p.setString('last_server', _server); });
                    _syncSettings();
                    if (_connected) _disconnect().then((_) { setState(() => _connecting = true); _startProxy(); });
                  })),
                _thinDiv(),
                _selectRow(L.tr('server'), filtered.isEmpty ? L.tr('none') : _server, () {
                  if (filtered.isEmpty) return;
                  _showSheet(L.tr('server'), filtered.map((s) => (s.name, s.name)).toList(), _server, (v) {
                    setState(() { _server = v; _testResult = ''; });
                    SharedPreferences.getInstance().then((p) => p.setString('last_server', v));
                    _syncSettings();
                    if (_connected) _disconnect().then((_) { setState(() => _connecting = true); _startProxy(); });
                  });
                }),
              ]),
            ),

            // Speed test
            if (_connected) ...[
              const SizedBox(height: 16),
              GestureDetector(
                onTap: _testing ? null : _runSpeedTest,
                child: Container(
                  width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08))),
                  child: Row(children: [
                    Icon(Icons.speed, size: 16, color: Colors.white.withValues(alpha: 0.3)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_testing ? L.tr('testing') : _testResult.isEmpty ? L.tr('speed_test') : _testResult.split('\n').first,
                      style: TextStyle(fontSize: 12, color: _testResult.isEmpty ? Colors.white38 : Colors.white, fontWeight: _testResult.isEmpty ? FontWeight.normal : FontWeight.w600))),
                    if (_testResult.isNotEmpty) GestureDetector(
                      onTap: () { Clipboard.setData(ClipboardData(text: 'Fogged Speed Test\nProtocol: $_protocol\nServer: $_server\n$_testResult')); _showMsg('Copied'); },
                      child: Icon(Icons.copy, size: 13, color: Colors.white.withValues(alpha: 0.3))),
                  ]),
                ),
              ),
            ],

            const SizedBox(height: 30),
          ]),
        ))),
      ]),
    );
  }

  Widget _settingsPanel() {
    return _SettingsScreen(
      accountNumber: _accountNumber, subStatus: _subStatus, subEndsAt: _subEndsAt,
      daysLeft: _daysLeft, referralCode: _referralCode, referralEarnings: _referralEarnings,
      totalReferrals: _totalReferrals, userRole: _userRole, uuid: _uuid,
      apiBase: _apiBase, debugLogs: _debugLogs, protocol: _protocol, server: _server,
      mode: _mode, onLogout: _logout, whitelistMode: _whitelistMode,
      onWhitelistChanged: (v) async {
        setState(() => _whitelistMode = v);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('whitelist_mode', v);
        if (_connected) await _setSystemProxy(true);
      },
      splitDomains: _splitDomains,
      onSplitDomainsChanged: (domains) async {
        setState(() => _splitDomains = domains);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList('split_domains', domains);
        if (_connected) await _setSystemProxy(true);
      },
    );
  }

  Widget _speedPanel() {
    return Container(
      color: const Color(0xFF0D0D0D),
      child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(L.tr('speed_test'), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 2)),
          const Spacer(),
          if (!_fullTesting && _connected) GestureDetector(
            onTap: _runFullSpeedTest,
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
              child: Text(L.tr('run_full_test'), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600))),
          ),
          if (_fullTesting) Text('${L.tr('testing_progress')} $_fullTestProgress/$_fullTestTotal',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
        ]),
        const SizedBox(height: 16),

        if (!_connected && _fullTestResults.isEmpty)
          Center(child: Padding(padding: const EdgeInsets.only(top: 60),
            child: Text(L.tr('connect_first'), style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 14))))
        else ...[
          // Quick test (current protocol+server)
          if (_connected) GestureDetector(
            onTap: _testing ? null : _runSpeedTest,
            child: Container(
              width: double.infinity, padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08))),
              child: Row(children: [
                Icon(Icons.speed, size: 18, color: Colors.white.withValues(alpha: 0.4)),
                const SizedBox(width: 10),
                Expanded(child: Text(_testing ? L.tr('testing') : _testResult.isEmpty ? '$_protocol — $_server' : _testResult,
                  style: TextStyle(fontSize: 12, color: _testResult.isEmpty ? Colors.white38 : Colors.white, fontWeight: FontWeight.w500))),
                if (_testResult.isNotEmpty) GestureDetector(
                  onTap: () { Clipboard.setData(ClipboardData(text: 'Fogged Speed Test\nProtocol: $_protocol\nServer: $_server\n$_testResult')); _showMsg(L.tr('copied')); },
                  child: Icon(Icons.copy, size: 13, color: Colors.white.withValues(alpha: 0.3))),
              ]),
            ),
          ),

          // Full test results table
          if (_fullTestResults.isNotEmpty) ...[
            const SizedBox(height: 16),
            Expanded(child: ListView.builder(
              itemCount: _fullTestResults.length,
              itemBuilder: (_, i) {
                final r = _fullTestResults[i];
                final isBest = i == 0 && !_fullTesting && r['speed'] != null;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: isBest ? Colors.green.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.02),
                    border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)))),
                  child: Row(children: [
                    if (isBest) Padding(padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.star, size: 12, color: Colors.green.shade300)),
                    Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(r['protocol'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                      Text(r['server'] ?? '', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 10)),
                    ])),
                    Expanded(flex: 2, child: Text(
                      r['speed'] != null ? '${(r['speed'] as double).toStringAsFixed(1)} Mbps' : r['status'] == 'testing' ? '...' : '--',
                      style: TextStyle(color: r['speed'] != null ? Colors.white : Colors.white30, fontSize: 12, fontWeight: FontWeight.w600),
                      textAlign: TextAlign.right)),
                    const SizedBox(width: 8),
                    SizedBox(width: 50, child: Text(
                      r['latency'] != null ? '${r['latency']}ms' : '',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 10),
                      textAlign: TextAlign.right)),
                    if (!_fullTesting && r['speed'] != null) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          setState(() { _protocol = r['protocol']; _server = r['server']; _navIndex = 0; });
                        },
                        child: Text(L.tr('use_this'), style: TextStyle(color: Colors.blue.shade300, fontSize: 10, fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ]),
                );
              },
            )),
          ],

          // SNI test section
          if (!_fullTesting && _sniResults.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(L.tr('sni_test'), style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ..._sniResults.asMap().entries.map((e) {
              final r = e.value;
              final working = r['status'] == 'working';
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)))),
                child: Row(children: [
                  Icon(working ? Icons.check_circle : Icons.cancel, size: 14, color: working ? Colors.green.shade300 : Colors.red.shade300),
                  const SizedBox(width: 8),
                  Expanded(child: Text('SNI ${e.key + 1}', style: const TextStyle(color: Colors.white, fontSize: 12))),
                  Text(r['latency'] != null ? '${r['latency']}ms' : '--',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11)),
                  const SizedBox(width: 8),
                  Text(working ? L.tr('working') : L.tr('blocked'),
                    style: TextStyle(color: working ? Colors.green.shade300 : Colors.red.shade300, fontSize: 10, fontWeight: FontWeight.w600)),
                ]),
              );
            }),
          ],
        ],
      ])),
    );
  }

  Future<void> _runFullSpeedTest() async {
    if (_fullTesting || !_connected) return;

    // Build list of all protocol+server combos
    final combos = <Map<String, String>>[];
    for (final proto in _protocols) {
      final servers = proto == 'VLESS+Reality' ? _servers.where((s) => s.protocol == 'vless')
          : proto == 'Hysteria2' ? _servers.where((s) => s.protocol == 'hysteria2')
          : _servers.where((s) => s.protocol == 'orcax');
      for (final srv in servers) {
        combos.add({'protocol': proto, 'server': srv.name, 'addr': srv.addr});
      }
    }
    if (combos.isEmpty) return;

    // Disconnect current, then test each combo
    await _disconnect();
    setState(() {
      _fullTesting = true;
      _fullTestProgress = 0;
      _fullTestTotal = combos.length;
      _fullTestResults = combos.map((c) => <String, dynamic>{'protocol': c['protocol'], 'server': c['server'], 'speed': null, 'latency': null, 'status': 'pending'}).toList();
    });

    for (int i = 0; i < combos.length; i++) {
      setState(() { _fullTestProgress = i + 1; _fullTestResults[i]['status'] = 'testing'; });

      final combo = combos[i];
      // Set protocol and server, connect, test, disconnect
      _protocol = combo['protocol']!;
      _server = combo['server']!;

      try {
        await _startProxy();
        // Wait for connection
        await Future.delayed(const Duration(seconds: 4));
        if (!_connected) { setState(() { _fullTestResults[i]['status'] = 'failed'; }); continue; }

        // Run speed test via curl
        final result = await Process.run('curl', [
          '-x', 'socks5h://127.0.0.1:1080', '-so', '/dev/null',
          '-w', '%{speed_download}|%{time_starttransfer}',
          '-r', '0-5242879', 'https://hel1-speed.hetzner.com/100MB.bin', '--max-time', '15',
        ]);
        final parts = result.stdout.toString().split('|');
        if (parts.length >= 2) {
          final speedBps = double.tryParse(parts[0]) ?? 0;
          final ttfb = double.tryParse(parts[1]) ?? 0;
          final mbps = (speedBps * 8) / 1000000;
          setState(() {
            _fullTestResults[i]['speed'] = mbps;
            _fullTestResults[i]['latency'] = (ttfb * 1000).round();
            _fullTestResults[i]['status'] = 'done';
          });
        }
      } catch (_) {
        setState(() { _fullTestResults[i]['status'] = 'failed'; });
      }

      await _disconnect();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // Sort by speed descending
    _fullTestResults.sort((a, b) => ((b['speed'] as double?) ?? 0).compareTo((a['speed'] as double?) ?? 0));
    setState(() => _fullTesting = false);

    // Report results to backend (privacy-preserving)
    _reportSpeedTests();

    // Run SNI test too
    _runSniTest();
  }

  Future<void> _reportSpeedTests() async {
    try {
      final results = _fullTestResults.where((r) => r['speed'] != null).map((r) => {
        'protocol': r['protocol'], 'server': r['server'], 'speed_mbps': r['speed'], 'latency_ms': r['latency'],
      }).toList();
      await http.post(Uri.parse('$_apiBase/speedtest/report'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uuid': _uuid, 'region': _mode, 'results': results}));
    } catch (_) {}
  }

  Future<void> _runSniTest() async {
    setState(() { _testingSni = true; _sniResults = []; });
    try {
      // Fetch SNI list from API
      final resp = await http.get(Uri.parse('$_apiBase/sni/list'));
      if (resp.statusCode != 200) return;
      final snis = (jsonDecode(resp.body) as List).cast<String>();
      if (snis.isEmpty) return;

      // Get a direct server IP to test against
      final directServers = _servers.where((s) => s.protocol == 'vless').toList();
      if (directServers.isEmpty) return;
      final serverIp = directServers.first.addr.split(':').first;

      for (final sni in snis) {
        try {
          final result = await Process.run('curl', [
            '--resolve', '$sni:443:$serverIp', 'https://$sni/',
            '-so', '/dev/null', '-w', '%{time_connect}', '--max-time', '5',
          ]);
          final connectTime = double.tryParse(result.stdout.toString().trim()) ?? 0;
          final working = result.exitCode == 0 && connectTime > 0 && connectTime < 5;
          setState(() => _sniResults.add({
            'sni': sni, 'latency': working ? (connectTime * 1000).round() : null, 'status': working ? 'working' : 'blocked',
          }));
        } catch (_) {
          setState(() => _sniResults.add({'sni': sni, 'latency': null, 'status': 'blocked'}));
        }
      }
    } catch (_) {}
    setState(() => _testingSni = false);
    // Report SNI results to backend
    try {
      await http.post(Uri.parse('$_apiBase/sni/report'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uuid': _uuid, 'country': _mode, 'results': _sniResults.map((r) => {
          'sni': r['sni'], 'latency_ms': r['latency'], 'status': r['status'],
        }).toList()}));
    } catch (_) {}
  }

  Widget _debugPanel() {
    return Container(
      color: const Color(0xFF0D0D0D),
      child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Debug Console', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 2)),
          const Spacer(),
          if (_debugLogs.isNotEmpty) GestureDetector(
            onTap: () { Clipboard.setData(ClipboardData(text: _debugLogs.join('\n'))); _showMsg('Copied'); },
            child: Row(children: [Icon(Icons.copy, size: 13, color: Colors.white.withValues(alpha: 0.3)), const SizedBox(width: 4),
              Text('Copy', style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.3)))]),
          ),
        ]),
        const SizedBox(height: 12),
        Expanded(child: Container(
          decoration: BoxDecoration(color: Colors.black, border: Border.all(color: Colors.white10), borderRadius: BorderRadius.circular(8)),
          child: _debugLogs.isEmpty
            ? Center(child: Text('No logs yet', style: TextStyle(color: Colors.white.withValues(alpha: 0.15), fontSize: 12)))
            : ListView.builder(controller: _debugScroll, itemCount: _debugLogs.length, padding: const EdgeInsets.all(8),
                itemBuilder: (_, i) => Text(_debugLogs[i], style: TextStyle(fontFamily: 'Courier', fontSize: 10,
                  color: _debugLogs[i].contains('err') || _debugLogs[i].contains('fail') ? Colors.red.shade300 :
                    _debugLogs[i].contains('OK') || _debugLogs[i].contains('connected') ? Colors.green.shade300 : Colors.white54))),
        )),
      ])),
    );
  }

  List<String> _checkedSites = [
    'youtube.com', 'instagram.com', 'twitter.com', 'facebook.com',
    'linkedin.com', 'discord.com', 'telegram.org', 'medium.com',
    'reddit.com', 'twitch.tv', 'spotify.com', 'pinterest.com',
    'soundcloud.com', 'bbc.com', 'dw.com', 'netflix.com',
    'tiktok.com', 'whatsapp.com', 'signal.org', 'proton.me',
  ];

  Widget _siteCheckerPanel() {
    return Container(
      color: const Color(0xFF0D0D0D),
      child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(L.tr('site_checker'), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 2)),
          const Spacer(),
          if (_connected && !_checkingSites) GestureDetector(
            onTap: _checkSites,
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
              child: Text(L.tr('check_all'), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600))),
          ),
          if (_checkingSites) SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white.withValues(alpha: 0.4))),
        ]),
        const SizedBox(height: 16),
        if (_blockedStats.isNotEmpty) Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(_blockedStats, style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 11)),
        ),
        if (!_connected && _siteResults.isEmpty)
          Center(child: Padding(padding: const EdgeInsets.only(top: 60),
            child: Text(L.tr('connect_first'), style: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 14))))
        else Expanded(child: ListView.builder(
          itemCount: _siteResults.isEmpty ? _checkedSites.length : _siteResults.length,
          itemBuilder: (_, i) {
            if (_siteResults.isEmpty) {
              return _siteRow(_checkedSites[i], null);
            }
            final r = _siteResults[i];
            return _siteRow(r['site'], r['working']);
          },
        )),
      ])),
    );
  }

  Widget _siteRow(String site, bool? working) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)))),
      child: Row(children: [
        Icon(working == null ? Icons.circle_outlined : working ? Icons.check_circle : Icons.cancel,
          size: 14, color: working == null ? Colors.white12 : working ? Colors.green.shade300 : Colors.red.shade300),
        const SizedBox(width: 10),
        Expanded(child: Text(site, style: const TextStyle(color: Colors.white, fontSize: 12))),
        Text(working == null ? '--' : working ? L.tr('working') : L.tr('blocked'),
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
            color: working == null ? Colors.white12 : working ? Colors.green.shade300 : Colors.red.shade300)),
      ]),
    );
  }

  String _blockedStats = '';

  Future<void> _fetchBlockedStats() async {
    try {
      final resp = await http.get(Uri.parse('$_apiBase/blocked/stats'));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        final total = j['total_blocked_domains'] ?? 0;
        if (total > 0) setState(() => _blockedStats = '${(total / 1000).round()}K domains blocked in Russia');
      }
    } catch (_) {}
  }

  Future<void> _checkSites() async {
    if (!_connected || _checkingSites) return;
    _fetchBlockedStats();
    setState(() { _checkingSites = true; _siteResults = []; });
    for (final site in _checkedSites) {
      try {
        bool working;
        if (Platform.isAndroid || Platform.isIOS) {
          // Mobile: use Dart HTTP directly (VPN handles routing)
          final resp = await http.get(Uri.parse('https://$site/')).timeout(const Duration(seconds: 8));
          working = resp.statusCode >= 200 && resp.statusCode < 400;
        } else {
          // Desktop: use curl through SOCKS proxy
          final result = await Process.run('curl', [
            '-x', 'socks5h://127.0.0.1:1080', '-so', '/dev/null',
            '-w', '%{http_code}', 'https://$site/', '--max-time', '8',
          ]);
          final code = int.tryParse(result.stdout.toString().trim()) ?? 0;
          working = code >= 200 && code < 400;
        }
        setState(() => _siteResults.add({'site': site, 'working': working}));
      } catch (_) {
        setState(() => _siteResults.add({'site': site, 'working': false}));
      }
    }
    setState(() => _checkingSites = false);
    // Report results to backend for analytics
    try {
      await http.post(Uri.parse('$_apiBase/sites/report'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uuid': _uuid, 'results': _siteResults.map((r) => {
          'site': r['site'], 'working': r['working'], 'server': _server, 'protocol': _protocol,
        }).toList()}));
    } catch (_) {}
  }

  Widget _statChip(String label, String value) {
    return Column(children: [
      Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 10)),
    ]);
  }

  Widget _selectRow(String label, String value, VoidCallback onTap) {
    return GestureDetector(onTap: onTap, child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
        const Spacer(),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(width: 6),
        Icon(Icons.chevron_right, size: 16, color: Colors.white.withValues(alpha: 0.2)),
      ]),
    ));
  }

  Widget _thinDiv() => Divider(color: Colors.white.withValues(alpha: 0.06), height: 1, indent: 14, endIndent: 14);

  // ── Auth screen ──

  Widget _languagePickerScreen() => Scaffold(
    backgroundColor: const Color(0xFF0A0A0A),
    body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Image.asset('assets/logo.png', width: 64, height: 64),
      const SizedBox(height: 24),
      const Text('FOGGED', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: 6, color: Colors.white)),
      const SizedBox(height: 40),
      const Text('Choose your language', style: TextStyle(fontSize: 14, color: Colors.white38)),
      const SizedBox(height: 20),
      for (final entry in [('en', 'English'), ('ru', 'Русский'), ('zh', '中文')])
        Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: SizedBox(width: 200, height: 44, child: ElevatedButton(
          onPressed: () async {
            L.setLang(entry.$1);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('lang', entry.$1);
            setState(() => _langPicked = true);
            _loadAuth();
          },
          style: ElevatedButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.08), foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: Text(entry.$2, style: const TextStyle(fontSize: 15, letterSpacing: 1)),
        ))),
    ])),
  );

  Widget _authScreen() => Scaffold(body: Stack(children: [
    CustomPaint(painter: _GridPainter(), size: Size.infinite),
    SafeArea(child: Center(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 40), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('FOGGED', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: 6, color: Colors.white)),
      const SizedBox(height: 8),
      Text(L.tr('secure_vpn'), style: TextStyle(fontSize: 12, letterSpacing: 2, color: Colors.white.withValues(alpha: 0.3))),
      const SizedBox(height: 50),

      if (!_codeRequested) ...[
        Text(L.tr('enter_telegram'), style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.5))),
        const SizedBox(height: 12),
        TextField(controller: _handleCtl, style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(hintText: '@username or User ID', hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2)),
            prefixIcon: Icon(Icons.person, color: Colors.white.withValues(alpha: 0.3), size: 18),
            filled: true, fillColor: Colors.white.withValues(alpha: 0.05),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))))),
        const SizedBox(height: 8),
        Text(L.tr('userid_help'), style: TextStyle(fontSize: 10, color: Colors.white.withValues(alpha: 0.2), height: 1.4), textAlign: TextAlign.center),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, height: 44, child: ElevatedButton(
          onPressed: _authLoading ? null : _requestCode,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.1), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: _authLoading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(L.tr('send_code'), style: const TextStyle(letterSpacing: 1)),
        )),
      ] else ...[
        Text(L.tr('enter_code'), style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.5))),
        const SizedBox(height: 6),
        Text('${(_codeTimer ~/ 60).toString().padLeft(2, '0')}:${(_codeTimer % 60).toString().padLeft(2, '0')}',
          style: TextStyle(fontSize: 11, fontFamily: 'Courier', color: _codeTimer > 60 ? Colors.white.withValues(alpha: 0.2) : _codeTimer > 0 ? Colors.orange.withValues(alpha: 0.5) : Colors.red.withValues(alpha: 0.5))),
        const SizedBox(height: 10),
        TextField(controller: _codeCtl, keyboardType: TextInputType.number, style: const TextStyle(color: Colors.white, fontSize: 20, letterSpacing: 8), textAlign: TextAlign.center,
          decoration: InputDecoration(hintText: '000000', hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.15), letterSpacing: 8),
            filled: true, fillColor: Colors.white.withValues(alpha: 0.05),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))))),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, height: 44, child: ElevatedButton(
          onPressed: (_authLoading || _codeTimer <= 0) ? null : _verifyCode,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: _codeTimer > 0 ? 0.1 : 0.03), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: _authLoading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(_codeTimer <= 0 ? 'Expired' : L.tr('verify'), style: const TextStyle(letterSpacing: 1)),
        )),
        const SizedBox(height: 12),
        GestureDetector(onTap: () => setState(() { _codeRequested = false; _codeCtl.clear(); _codeTimer = 0; }), child: Text(L.tr('back'), style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.3)))),
      ],
      const SizedBox(height: 30),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (final entry in [('en', 'EN'), ('ru', 'RU'), ('zh', 'ZH')]) GestureDetector(
          onTap: () => _setLang(entry.$1),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(entry.$2, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: L.lang == entry.$1 ? Colors.white : Colors.white24))),
        ),
      ]),
    ]))))),
  ]));

  void _showSheet(String title, List<(String, String)> options, String current, void Function(String) onSelect) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12),
        Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        Text(title, style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ...options.map((o) => ListTile(
          title: Text(o.$2, style: TextStyle(color: o.$1 == current ? Colors.white : Colors.white54, fontSize: 14, fontWeight: o.$1 == current ? FontWeight.w600 : FontWeight.normal)),
          trailing: o.$1 == current ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
          onTap: () { Navigator.pop(context); onSelect(o.$1); },
        )),
        const SizedBox(height: 16),
      ])),
    );
  }


}

// ── In-App Update Dialog (Surfshark-style) ──

class _UpdateDialog extends StatefulWidget {
  final String version, notes, downloadUrl;
  final VoidCallback onSkip, onLater;
  const _UpdateDialog({required this.version, required this.notes, required this.downloadUrl, required this.onSkip, required this.onLater});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  double _progress = 0;
  String _status = '';

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0A0A0A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      child: Container(
        width: 340, padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Image.asset('assets/logo.png', width: 36, height: 36),
          const SizedBox(height: 10),
          Text('v${widget.version}', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 2)),
          if (widget.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(widget.notes, textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11, height: 1.4)),
          ],
          const SizedBox(height: 16),

          if (_downloading) ...[
            ClipRRect(borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: _progress, backgroundColor: Colors.white.withValues(alpha: 0.06),
                valueColor: AlwaysStoppedAnimation(Colors.white.withValues(alpha: 0.8)), minHeight: 3)),
            const SizedBox(height: 6),
            Text(_status, style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 10)),
          ] else ...[
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              GestureDetector(
                onTap: widget.onLater,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
                  decoration: BoxDecoration(border: Border.all(color: Colors.white.withValues(alpha: 0.1)), borderRadius: BorderRadius.circular(8)),
                  child: Text('Later', style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _installUpdate,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: const Text('Update', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  Future<void> _installUpdate() async {
    setState(() { _downloading = true; _status = 'Downloading...'; _progress = 0; });

    try {
      final request = http.Request('GET', Uri.parse(widget.downloadUrl));
      final response = await request.send();
      final totalBytes = response.contentLength ?? 0;
      var receivedBytes = 0;
      final chunks = <List<int>>[];

      await for (final chunk in response.stream) {
        chunks.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          setState(() { _progress = receivedBytes / totalBytes; _status = '${(receivedBytes / 1048576).toStringAsFixed(1)} / ${(totalBytes / 1048576).toStringAsFixed(1)} MB'; });
        }
      }

      final bytes = chunks.expand((c) => c).toList();
      setState(() { _status = 'Installing...'; _progress = 1.0; });

      if (Platform.isMacOS) {
        // Save as ZIP, extract silently, copy to Applications — no Finder popups
        final zipPath = '/tmp/Fogged-Update.zip';
        final extractDir = '/tmp/Fogged-Update';
        await File(zipPath).writeAsBytes(bytes);
        setState(() => _status = 'Extracting...');

        // Clean old extract dir
        if (await Directory(extractDir).exists()) await Directory(extractDir).delete(recursive: true);
        await Directory(extractDir).create();

        // Unzip silently
        final unzip = await Process.run('unzip', ['-o', '-q', zipPath, '-d', extractDir]);
        if (unzip.exitCode == 0) {
          // Find the .app inside
          final appDir = await Process.run('bash', ['-c', 'find $extractDir -name "*.app" -maxdepth 2 | head -1'.replaceAll('\$extractDir', extractDir)]);
          final appPath = appDir.stdout.toString().trim();
          if (appPath.isNotEmpty) {
            setState(() => _status = 'Replacing app...');
            await Process.run('bash', ['-c', 'rm -rf /Applications/Fogged.app && cp -R "$appPath" /Applications/']);

            // Cleanup update files
            await File(zipPath).delete();
            await Directory(extractDir).delete(recursive: true);

            // Mark this version as installed so we don't prompt again
            final p = await SharedPreferences.getInstance();
            await p.setString('update_installed_version', widget.version);
            setState(() => _status = 'Restarting...');
            final script = '/tmp/fogged-relaunch.sh';
            await File(script).writeAsString('#!/bin/bash\nsleep 2\nopen /Applications/Fogged.app\nrm -f \$0\n');
            await Process.run('chmod', ['+x', script]);
            Process.start('nohup', [script], mode: ProcessStartMode.detached);
            await Future.delayed(const Duration(seconds: 1));
            exit(0);
          }
        }
        // Cleanup on failure
        try { await File(zipPath).delete(); } catch (_) {}
        try { await Directory(extractDir).delete(recursive: true); } catch (_) {}
        setState(() => _status = 'Install failed');
      } else if (Platform.isWindows) {
        final exePath = '${Platform.environment['TEMP']}\\Fogged-Setup.exe';
        await File(exePath).writeAsBytes(bytes);
        setState(() => _status = 'Running installer...');
        final p = await SharedPreferences.getInstance();
        await p.setString('update_installed_version', widget.version);
        Process.run(exePath, ['/S']);
        await Future.delayed(const Duration(seconds: 2));
        exit(0);
      }
    } catch (e) {
      setState(() { _downloading = false; _status = 'Error: $e'; });
    }
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.white.withValues(alpha: 0.02)..strokeWidth = 0.5;
    for (double x = 0; x < size.width; x += 60) canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    for (double y = 0; y < size.height; y += 60) canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Settings Screen ──

class _SettingsScreen extends StatefulWidget {
  final String accountNumber, subStatus, subEndsAt, daysLeft, referralCode, userRole, uuid, apiBase, protocol, server, mode;
  final double referralEarnings;
  final int totalReferrals;
  final List<String> debugLogs;
  final VoidCallback onLogout;
  final bool whitelistMode;
  final ValueChanged<bool> onWhitelistChanged;
  final List<String> splitDomains;
  final ValueChanged<List<String>> onSplitDomainsChanged;

  const _SettingsScreen({
    required this.accountNumber, required this.subStatus, required this.subEndsAt,
    required this.daysLeft, required this.referralCode, required this.referralEarnings,
    required this.totalReferrals, required this.userRole, required this.uuid,
    required this.apiBase, required this.debugLogs, required this.protocol,
    required this.server, required this.mode, required this.onLogout,
    required this.whitelistMode, required this.onWhitelistChanged,
    required this.splitDomains, required this.onSplitDomainsChanged,
  });

  @override
  State<_SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<_SettingsScreen> {
  final _supportCtl = TextEditingController();
  final _domainCtl = TextEditingController();
  bool _includeDebug = true;
  bool _sending = false;
  bool _autoStart = false;
  bool _killSwitch = false;

  @override
  void initState() {
    super.initState();
    _loadSystemPrefs();
  }

  Future<void> _loadSystemPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoStart = prefs.getBool('auto_start') ?? false;
      _killSwitch = prefs.getBool('kill_switch') ?? false;
    });
  }

  void _addSplitDomain() {
    final domain = _domainCtl.text.trim().toLowerCase();
    if (domain.isEmpty || !domain.contains('.')) return;
    if (!widget.splitDomains.contains(domain)) {
      widget.onSplitDomainsChanged([...widget.splitDomains, domain]);
    }
    _domainCtl.clear();
  }

  Future<void> _setAutoStart(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_start', enabled);
    setState(() => _autoStart = enabled);

    if (Platform.isMacOS) {
      final plistPath = '${Platform.environment['HOME']}/Library/LaunchAgents/net.fogged.vpn.plist';
      if (enabled) {
        final appPath = Platform.resolvedExecutable;
        final plist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>net.fogged.vpn</string>
  <key>ProgramArguments</key><array><string>$appPath</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>''';
        await File(plistPath).writeAsString(plist);
      } else {
        try { await File(plistPath).delete(); } catch (_) {}
      }
    }
  }

  Future<void> _setKillSwitch(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('kill_switch', enabled);
    setState(() => _killSwitch = enabled);

    if (Platform.isMacOS) {
      if (enabled) {
        // Block all traffic except localhost (SOCKS proxy) using pf
        final rules = 'block all\npass on lo0\npass out proto tcp to 127.0.0.1 port 1080\npass out proto udp to any port 53\n';
        await File('/tmp/fogged-killswitch.conf').writeAsString(rules);
        await Process.run('sudo', ['pfctl', '-ef', '/tmp/fogged-killswitch.conf']);
      } else {
        await Process.run('sudo', ['pfctl', '-d']);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final refLink = 'https://t.me/foggedvpnbot?start=${widget.referralCode}';
    return Container(
      color: const Color(0xFF0D0D0D),
      child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header
          Text(L.tr('settings'), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 2)),
          const SizedBox(height: 24),

          // Account section
          _sectionTitle(L.tr('account')),
          _card([
            _infoRow(L.tr('account'), widget.accountNumber.isEmpty ? '--' : widget.accountNumber),
            _infoRow('Status', widget.subStatus.isEmpty ? '--' : widget.subStatus),
            _infoRow(L.tr('subscription'), widget.daysLeft == '?' ? '--' : '${widget.daysLeft} ${L.tr('days_left')}'),
            if (widget.subEndsAt.isNotEmpty) _infoRow(L.tr('expired'), widget.subEndsAt.split('T').first),
          ]),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, height: 40, child: ElevatedButton(
            onPressed: () => Process.run('open', ['https://t.me/foggedvpnbot']),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.08), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: Text(L.tr('subscribe'), style: const TextStyle(fontSize: 13, letterSpacing: 1)),
          )),
          const SizedBox(height: 20),

          // Referral section
          _sectionTitle(L.tr('referrals')),
          _card([
            _infoRow(L.tr('referral_link'), widget.referralCode.isEmpty ? '--' : widget.referralCode),
            _infoRow(L.tr('referrals'), '${widget.totalReferrals}'),
            _infoRow(L.tr('earnings'), '\$${widget.referralEarnings.toStringAsFixed(2)}'),
          ]),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () { Clipboard.setData(ClipboardData(text: refLink)); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied'))); },
            child: Container(
              width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white.withValues(alpha: 0.1))),
              child: Row(children: [
                Expanded(child: Text(refLink, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11), overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Icon(Icons.copy, size: 14, color: Colors.white.withValues(alpha: 0.3)),
              ]),
            ),
          ),
          const SizedBox(height: 20),

          // Whitelist mode (Russia)
          _sectionTitle('Whitelist Mode'),
          Container(
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withValues(alpha: 0.08))),
            child: SwitchListTile(
              value: widget.whitelistMode,
              onChanged: widget.onWhitelistChanged,
              title: const Text('Bypass whitelisted sites', style: TextStyle(color: Colors.white, fontSize: 13)),
              subtitle: Text('VK, Yandex, Sber, Gosuslugi go direct', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11)),
              activeColor: Colors.white,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
            ),
          ),
          const SizedBox(height: 20),

          // Split tunnel (custom bypass domains)
          _sectionTitle(L.tr('split_tunnel')),
          Container(
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withValues(alpha: 0.08))),
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(L.tr('domain_routing'), style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(
                  controller: _domainCtl, style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'example.com', hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.15)),
                    isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    filled: true, fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none)),
                  onSubmitted: (_) => _addSplitDomain(),
                )),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _addSplitDomain,
                  child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
                    child: Text(L.tr('add_domain'), style: const TextStyle(color: Colors.white, fontSize: 11))),
                ),
              ]),
              if (widget.splitDomains.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...widget.splitDomains.map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    Text(d, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () { final updated = List<String>.from(widget.splitDomains)..remove(d); widget.onSplitDomainsChanged(updated); },
                      child: Icon(Icons.close, size: 14, color: Colors.white.withValues(alpha: 0.3))),
                  ]),
                )),
              ],
            ]),
          ),
          const SizedBox(height: 20),

          // Auto-start + Kill switch
          _sectionTitle('System'),
          Container(
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withValues(alpha: 0.08))),
            child: Column(children: [
              SwitchListTile(
                value: _autoStart,
                onChanged: Platform.isMacOS ? (v) => _setAutoStart(v) : null,
                title: Text('Auto-start on boot', style: TextStyle(color: Colors.white.withValues(alpha: Platform.isMacOS ? 1.0 : 0.3), fontSize: 13)),
                subtitle: Text(Platform.isMacOS ? 'Launch Fogged when you log in' : 'macOS only', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11)),
                activeColor: Colors.white,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
              ),
              Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
              SwitchListTile(
                value: _killSwitch,
                onChanged: Platform.isMacOS ? (v) => _setKillSwitch(v) : null,
                title: Text('Kill switch', style: TextStyle(color: Colors.white.withValues(alpha: Platform.isMacOS ? 1.0 : 0.3), fontSize: 13)),
                subtitle: Text(Platform.isMacOS ? 'Block internet if VPN disconnects' : 'macOS only', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11)),
                activeColor: Colors.white,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
              ),
            ]),
          ),
          const SizedBox(height: 20),

          // Support section
          _sectionTitle(L.tr('support')),
          TextField(
            controller: _supportCtl, maxLines: 3,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: L.tr('report_hint'), hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2)),
              filled: true, fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Checkbox(
              value: _includeDebug,
              onChanged: (v) => setState(() => _includeDebug = v ?? false),
              fillColor: WidgetStateProperty.all(Colors.white.withValues(alpha: 0.1)),
              checkColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            ),
            Text(L.tr('include_debug'), style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
            const Spacer(),
            SizedBox(height: 36, child: ElevatedButton(
              onPressed: _sending ? null : _sendSupport,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.08), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              child: _sending
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(L.tr('send_report'), style: const TextStyle(fontSize: 12)),
            )),
          ]),
          const SizedBox(height: 24),

          // Language
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (final entry in [('en', 'EN'), ('ru', 'RU'), ('zh', 'ZH')]) Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: GestureDetector(
                onTap: () async {
                  L.setLang(entry.$1);
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('lang', entry.$1);
                  setState(() {});
                },
                child: Text(entry.$2, style: TextStyle(fontSize: 13, fontWeight: L.lang == entry.$1 ? FontWeight.bold : FontWeight.normal, color: L.lang == entry.$1 ? Colors.white : Colors.white30)),
              ),
            ),
          ]),
          const SizedBox(height: 16),

          // Logout
          // Check for updates button
          Center(child: GestureDetector(
            onTap: () async {
              try {
                final resp = await http.get(Uri.parse('${widget.apiBase}/version'));
                if (resp.statusCode == 200) {
                  final j = jsonDecode(resp.body);
                  final latest = j['version'] as String? ?? '';
                  final info = await PackageInfo.fromPlatform();
                  if (latest == info.version || latest.isEmpty) {
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You\'re on the latest version')));
                  } else {
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('v$latest available — restart app to update')));
                    // Clear the dismissed/installed flags so the update dialog shows on next launch
                    final p = await SharedPreferences.getInstance();
                    await p.remove('update_dismissed_at');
                    await p.remove('update_installed_version');
                  }
                }
              } catch (_) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not check for updates')));
              }
            },
            child: Text('Check for updates', style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.3))),
          )),
          const SizedBox(height: 16),

          Center(child: GestureDetector(
            onTap: widget.onLogout,
            child: Text(L.tr('logout'), style: TextStyle(fontSize: 12, color: Colors.red.shade300)),
          )),
          const SizedBox(height: 30),
        ])),
    );
  }

  Future<void> _sendSupport() async {
    final text = _supportCtl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      var body = text;
      if (_includeDebug) {
        body += '\n\n--- Debug Info ---\n'
            'Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n'
            'Protocol: ${widget.protocol}\n'
            'Server: ${widget.server}\n'
            'Region: ${widget.mode}\n'
            'Account: ${widget.accountNumber}\n'
            'Sub expires: ${widget.subEndsAt.split('T').first}\n'
            'Last logs:\n${widget.debugLogs.reversed.take(20).join('\n')}';
      }
      await http.post(Uri.parse('${widget.apiBase}/support/create'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uuid': widget.uuid, 'message': body}));
      _supportCtl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L.tr('report_sent'))));
        setState(() => _sending = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() => _sending = false);
      }
    }
  }

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(t, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1)),
  );

  Widget _card(List<Widget> children) => Container(
    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withValues(alpha: 0.08))),
    child: Column(children: children),
  );

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 13)),
      Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
    ]),
  );
}
