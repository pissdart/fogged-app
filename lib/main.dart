import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'l10n/strings.dart';
import 'models/vpn_server.dart';
import 'services/vpn_config.dart';

part 'widgets/update_dialog.dart';
part 'widgets/error_dialog.dart';
part 'widgets/grid_painter.dart';
part 'screens/settings_screen.dart';

// Sentry DSN — baked in at build time via --dart-define=SENTRY_DSN=... .
// Leave empty for local/debug builds; Sentry auto-disables when DSN is empty.
const String _sentryDsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Single-instance guard — if another Fogged is already running, kill it
  // before we proceed. The in-app updater's helper script tries to wait
  // for the prior PID + pgrep -x Fogged before swapping, but if a tray-
  // resident or crashed instance hangs around, two Fogged processes both
  // fight for 127.0.0.1:1080 (sing-box / xray / orcax-connect's SOCKS port)
  // and FATAL with "bind: address already in use". Self-pid is exempted.
  if (Platform.isMacOS || Platform.isLinux) {
    try {
      final my = pid;
      final r = await Process.run('pgrep', ['-x', 'Fogged']);
      final others = (r.stdout as String).split('\n')
          .map((s) => int.tryParse(s.trim()))
          .where((p) => p != null && p != my)
          .map((p) => p!)
          .toList();
      for (final p in others) {
        Process.run('kill', ['-TERM', '$p']);
      }
      if (others.isNotEmpty) {
        // Give the SIGTERMed process(es) up to 1.5s to release ports.
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    } catch (_) {}
  }
  await SentryFlutter.init(
    (opts) {
      opts.dsn = _sentryDsn;
      // Don't ship anything off-device in debug builds; only shipped (release)
      // builds produced with --dart-define=SENTRY_DSN=... actually report.
      opts.debug = false;
      opts.environment = const bool.fromEnvironment('dart.vm.product')
          ? 'release'
          : 'debug';
      opts.tracesSampleRate = 0.1;
      // Never send user IDs / request bodies — we don't control what lands there.
      opts.sendDefaultPii = false;
      opts.attachScreenshot = false;
      // Strip local routes/ports — CI should `flutter_symbols upload-debug-symbols`
      // if it wants readable stack traces.
    },
    appRunner: () {
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        Sentry.captureException(details.exception, stackTrace: details.stack);
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        Sentry.captureException(error, stackTrace: stack);
        return true;
      };
      runApp(const FoggedApp());
    },
  );
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
  static const _secureStorage = FlutterSecureStorage();
  // Fallback to SharedPreferences when keychain fails (unsigned macOS builds,
  // missing entitlements, etc.). UUID/telegram handle/vk link aren't highly
  // sensitive — they get transmitted in every sub URL fetch anyway.
  Future<String?> _secRead(String key) async {
    try {
      final v = await _secureStorage.read(key: key);
      if (v != null) return v;
    } catch (_) { /* fall through to prefs */ }
    final p = await SharedPreferences.getInstance();
    return p.getString('sec_$key');
  }
  Future<void> _secWrite(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
      return;
    } catch (_) { /* fall through to prefs */ }
    final p = await SharedPreferences.getInstance();
    await p.setString('sec_$key', value);
  }
  Future<void> _secDelete(String key) async {
    try { await _secureStorage.delete(key: key); } catch (_) {}
    final p = await SharedPreferences.getInstance();
    await p.remove('sec_$key');
  }
  bool _authLoading = false;
  bool _codeRequested = false;
  int _codeTimer = 0; // seconds remaining
  final _handleCtl = TextEditingController();
  final _codeCtl = TextEditingController();

  // Secure temp directory for config files (randomized, cleaned on disconnect)
  Directory? _tempDir;
  String _tempPath(String name) {
    _tempDir ??= Directory.systemTemp.createTempSync('fogged_');
    return '${_tempDir!.path}/$name';
  }
  void _cleanupTemp() {
    try { _tempDir?.deleteSync(recursive: true); } catch (_) {}
    _tempDir = null;
  }

  // Connection
  bool _connected = false;
  bool _connecting = false;
  String _protocol = 'VLESS+Reality';
  String _server = '';
  String _uptime = '--';
  String _downloaded = '0 B';
  Process? _proxyProcess;
  Process? _shimProcess; // domain-bypass shim (orcax-connect --upstream-socks) for xray/hy2
  Process? _blackoutProcess; // vk-turn-client subprocess (VK TURN fallback)
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
  /// Set true by the Stop button while a full speed test is running.
  /// Checked between combos and used as the cancel signal.
  bool _fullTestCancel = false;
  int _fullTestProgress = 0;
  int _fullTestTotal = 0;
  List<Map<String, dynamic>> _fullTestResults = [];

  // Site checker
  bool _checkingSites = false;
  List<Map<String, dynamic>> _siteResults = [];

  // SNI test
  List<Map<String, dynamic>> _sniResults = [];

  // Split tunnel custom domains
  List<String> _splitDomains = [];

  // Debug
  final List<String> _debugLogs = [];
  final _debugScroll = ScrollController();

  // Domain-bypass mode: Russian banking/gov/social apps go direct instead of
  // tunneling through the foreign VPN exit (avoids their foreign-IP checks).
  // Name NOT to be confused with the VK TURN "whitelist" server archetype —
  // that one's triggered by transport=vkturn on the selected server, not by
  // this flag. See ops/runbooks/protocols.md for the server archetypes.
  bool _domainBypass = false;

  // Blackout Mode: tunnel traffic through VK voice-call TURN server when
  // Russia shuts everything off except VK/Yandex (e.g. drone attacks).
  String _vkCallLink = '';

  // Account info (from /account/{uuid})
  String _accountNumber = '';
  String _subStatus = '';
  String _subEndsAt = '';
  String _referralCode = '';
  double _referralEarnings = 0.0;
  int _totalReferrals = 0;
  String _userRole = 'user'; // admin, supermod, user
  int _deviceLimit = 0;
  int? _devicesUsed; // null when server hasn't reported yet
  String _subTier = '';

  static const _protocols = ['VLESS+Reality', 'Hysteria2', 'OrcaX Pro Max'];
  static const _apiEndpoints = [
    'https://dl.fogged.net',           // Primary (Cloudflare-fronted)
    'https://fogged-api.anon-dev.workers.dev', // Cloudflare Worker #1
    'https://fogged-api-2.anon-dev.workers.dev', // Cloudflare Worker #2
    'https://fogged-api-3.anon-dev.workers.dev', // Cloudflare Worker #3
  ];
  String _apiBase = _apiEndpoints.first;
  int _apiEndpointIndex = 0;
  String _appVersion = '1.7.3'; // Updated from PackageInfo at runtime

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
    _probeApiAndLoad();
    // Check for updates on every app start (all platforms)
    Future.delayed(const Duration(seconds: 2), _checkForUpdate);
  }

  @override
  void dispose() {
    _apiRecoveryTimer?.cancel();
    _pulseController.dispose();
    _disconnect();
    super.dispose();
  }

  /// Probe API endpoints in order; use first that responds.
  /// On total failure (all endpoints down — network problem, DPI block of
  /// every domain, etc.) we load cached auth + servers from disk so the user
  /// has a usable app state, then schedule a background re-probe loop so
  /// we auto-recover once connectivity returns. No more "hope for recovery."
  Future<void> _probeApiAndLoad() async {
    for (var i = 0; i < _apiEndpoints.length; i++) {
      try {
        await http.get(Uri.parse('${_apiEndpoints[i]}/health')).timeout(const Duration(seconds: 3));
        _apiBase = _apiEndpoints[i];
        _apiEndpointIndex = i;
        if (i > 0) debugPrint('Using fallback API #$i: ${_apiEndpoints[i]}');
        _loadAuth();
        return;
      } catch (_) {
        debugPrint('API endpoint #$i unreachable: ${_apiEndpoints[i]}');
      }
    }
    // All endpoints down. Don't leave the user with a half-initialized app:
    //   1) Fall back to the cached subscription (loaded by _fetchSubscription)
    //   2) Show a non-blocking banner via _addLog (user sees "offline")
    //   3) Start a background re-probe — try again every 30s until we get a
    //      response, then swap _apiBase live and refetch.
    debugPrint('All API endpoints unreachable — entering cached-only mode');
    _apiBase = _apiEndpoints[0]; // nominal primary; will be overwritten on recovery
    _apiEndpointIndex = 0;
    _addLog('Offline: using cached servers. Will auto-reconnect when network returns.');
    _loadAuth();
    _startBackgroundApiRecovery();
  }

  Timer? _apiRecoveryTimer;

  /// Background re-probe loop. Fires every 30s while `_usingFallbackApi` is
  /// true AND no endpoint has responded. First success cancels the timer and
  /// triggers a subscription refresh so servers land before the user connects.
  void _startBackgroundApiRecovery() {
    _apiRecoveryTimer?.cancel();
    _apiRecoveryTimer = Timer.periodic(const Duration(seconds: 30), (t) async {
      if (!mounted) { t.cancel(); return; }
      for (var i = 0; i < _apiEndpoints.length; i++) {
        try {
          await http.get(Uri.parse('${_apiEndpoints[i]}/health')).timeout(const Duration(seconds: 3));
          _apiBase = _apiEndpoints[i];
          _apiEndpointIndex = i;
          _addLog('API reachable again: ${_apiEndpoints[i]}');
          t.cancel();
          _apiRecoveryTimer = null;
          // Refresh servers now that we're back online.
          if (_uuid.isNotEmpty) unawaited(_fetchSubscription());
          return;
        } catch (_) {}
      }
    });
  }

  /// Cycle to next API endpoint on request failure; returns true if more endpoints available
  Future<bool> _cycleApiEndpoint() async {
    final startIndex = _apiEndpointIndex;
    for (var i = 1; i < _apiEndpoints.length; i++) {
      final idx = (startIndex + i) % _apiEndpoints.length;
      try {
        await http.get(Uri.parse('${_apiEndpoints[idx]}/health')).timeout(const Duration(seconds: 3));
        _apiBase = _apiEndpoints[idx];
        _apiEndpointIndex = idx;
        debugPrint('Cycled to API endpoint #$idx: ${_apiEndpoints[idx]}');
        return true;
      } catch (_) {}
    }
    return false;
  }

  // ── Auth ──

  Future<void> _loadAuth() async {
    final prefs = await SharedPreferences.getInstance();
    // Read UUID from secure storage (migrate from SharedPreferences if needed)
    var uuid = await _secRead('uuid') ?? '';
    final handle = await _secRead('telegram_handle') ?? '';
    // Migration: if UUID in SharedPreferences but not in secure storage, migrate
    if (uuid.isEmpty) {
      uuid = prefs.getString('uuid') ?? '';
      if (uuid.isNotEmpty) {
        await _secWrite('uuid', uuid);
        await _secWrite('telegram_handle', prefs.getString('telegram_handle') ?? '');
        await prefs.remove('uuid'); // clean up plain storage
        await prefs.remove('telegram_handle');
      }
    }
    final lang = prefs.getString('lang');
    if (lang == null) {
      // First launch — show language picker
      setState(() => _langPicked = false);
      return;
    }
    L.setLang(['ru', 'zh'].contains(lang) ? lang : 'en');
    _domainBypass = prefs.getBool('whitelist_mode') ?? false;
    _splitDomains = prefs.getStringList('split_domains') ?? [];
    _vkCallLink = await _secRead('vk_call_link') ?? '';
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
      // Auto-connect if user was connected last session or has auto-start enabled.
      //
      // Important guard: if the cached `_server` is a vk-turn (whitelist)
      // entry, DON'T silently auto-connect. vk-turn requires the user to
      // solve a VK captcha in their browser every session, and silently
      // launching it on app-open looked to support like the app was
      // randomly opening a captcha URL. Forcing the user to tap Connect
      // when on a vk-turn server keeps captcha-popup tied to a user gesture.
      final wasConnected = prefs.getBool('was_connected') ?? false;
      final autoStart = prefs.getBool('auto_start') ?? false;
      if ((wasConnected || autoStart) && _filteredServers.isNotEmpty) {
        final selected = _filteredServers.firstWhere(
          (s) => s.name == _server,
          orElse: () => _filteredServers.first,
        );
        final isVkTurn = selected.params['transport'] == 'vkturn';
        if (isVkTurn) {
          _addLog('skipping auto-connect: last server uses vk-turn (captcha required)');
        } else {
          setState(() => _connecting = true);
          _startProxy();
        }
      }
      // Background refresh: re-fetch subscription every 5 minutes
      _startSubscriptionRefresh();
    }
  }

  void _startSubscriptionRefresh() {
    Future.delayed(const Duration(minutes: 5), () async {
      if (!mounted || _uuid.isEmpty) return;
      await _fetchSubscription();
      _startSubscriptionRefresh(); // schedule next
    });
  }

  Future<void> _fetchAccountInfo() async {
    if (_uuid.isEmpty) return;
    try {
      final resp = await http.get(Uri.parse('$_apiBase/account/$_uuid')).timeout(const Duration(seconds: 10));
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
          _deviceLimit = (j['device_limit'] ?? 0).toInt();
          _devicesUsed = j['devices_used'] is int ? j['devices_used'] as int : null;
          _subTier = j['subscription_tier'] ?? '';
          if (_protocol.startsWith('OrcaX')) _protocol = 'VLESS+Reality';
        });
        // Cache server-provisioned VK blackout link (used only when user
        // toggles Blackout Mode — user never sees this value)
        final link = j['blackout_link'] as String?;
        if (link != null && link.isNotEmpty) {
          _vkCallLink = link;
          await _secWrite('vk_call_link', link);
        }
        // Load cloud-synced app settings if present
        final settings = j['app_settings'];
        if (settings is Map) {
          final prefs = await SharedPreferences.getInstance();
          if (settings['whitelist_mode'] != null && !prefs.containsKey('whitelist_mode')) {
            _domainBypass = settings['whitelist_mode'] == true;
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
          'whitelist_mode': _domainBypass,
          'split_domains': _splitDomains,
          'protocol': _protocol,
          'server': _server,
          'mode': _mode,
        })).timeout(const Duration(seconds: 10));
    } catch (e) { debugPrint('Settings sync: $e'); }
  }

  /// Auto-update check at app launch. Silent unless an update is available.
  /// Respects the 24h dismissed-at window and the skipped-version flag.
  Future<void> _checkForUpdate() => _runUpdateCheck(forceShow: false);

  /// Manual update check from settings. Always shows a popup matching the
  /// update-dialog style — either the install prompt, the up-to-date status,
  /// or an error. Replaces the previous bottom-bar SnackBars.
  Future<void> _checkForUpdateForced() => _runUpdateCheck(forceShow: true);

  Future<void> _runUpdateCheck({required bool forceShow}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (forceShow) {
        // User explicitly asked — clear all dismissal flags so a previously
        // skipped/snoozed version still surfaces.
        await prefs.remove('update_dismissed_at');
        await prefs.remove('update_installed_version');
        await prefs.remove('update_skipped_version');
      }
      final lastDismissed = prefs.getInt('update_dismissed_at') ?? 0;
      final skippedVersion = prefs.getString('update_skipped_version') ?? '';
      final installedVersion = prefs.getString('update_installed_version') ?? '';
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!forceShow && now - lastDismissed < 86400000) return;

      final resp = await http.get(Uri.parse('$_apiBase/version')).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        if (forceShow && mounted) _showStatus(L.tr('update_check_failed'), '');
        return;
      }
      final j = jsonDecode(resp.body);
      final latest = j['version'] as String? ?? _appVersion;
      // Server may emit per-language notes (notes_en/ru/zh). Pick the user's
      // chosen language; fall back to the legacy single `notes` field on
      // older deployments or empty translation slots.
      final localized = j['notes_${L.lang}'] as String?;
      final notes = (localized != null && localized.isNotEmpty)
          ? localized
          : (j['notes'] as String? ?? 'Improvements and bug fixes.');
      final hasUpdate = _isNewer(latest, _appVersion) && latest != skippedVersion && latest != installedVersion;

      if (!hasUpdate) {
        if (forceShow && mounted) _showStatus('v$_appVersion', L.tr('up_to_date'));
        return;
      }

      final downloadUrl = Platform.isMacOS ? (j['download_macos'] as String? ?? '')
          : Platform.isWindows ? (j['download_windows'] as String? ?? '')
          : (j['download_android'] as String? ?? '');
      final expectedHash = Platform.isMacOS ? (j['sha256_macos'] as String? ?? '')
          : Platform.isWindows ? (j['sha256_windows'] as String? ?? '')
          : (j['sha256_android'] as String? ?? '');
      if (downloadUrl.isEmpty || !mounted) return;

      showDialog(context: context, barrierDismissible: true, builder: (ctx) =>
        _UpdateDialog(version: latest, notes: notes, downloadUrl: downloadUrl, expectedHash: expectedHash, onSkip: () async {
          Navigator.pop(ctx);
          final p = await SharedPreferences.getInstance();
          await p.setString('update_skipped_version', latest);
        }, onLater: () async {
          Navigator.pop(ctx);
          final p = await SharedPreferences.getInstance();
          await p.setInt('update_dismissed_at', DateTime.now().millisecondsSinceEpoch);
        }),
      );
    } catch (e) {
      debugPrint('Update check: $e');
      if (forceShow && mounted) _showStatus(L.tr('update_check_failed'), '');
    }
  }

  void _showStatus(String title, String body) {
    showDialog(context: context, barrierDismissible: true, builder: (ctx) =>
      _UpdateStatusDialog(title: title, body: body, onClose: () => Navigator.pop(ctx)),
    );
  }

  /// Compare semver: returns true if a > b
  bool _isNewer(String a, String b) {
    final ap = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final bp = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    while (ap.length < 3) ap.add(0);
    while (bp.length < 3) bp.add(0);
    for (var i = 0; i < 3; i++) {
      if (ap[i] > bp[i]) return true;
      if (ap[i] < bp[i]) return false;
    }
    return false;
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
    // Numeric-only User ID. Username sign-in is no longer supported because
    // it required Telegram to expose @handles, which not everyone has set.
    if (!RegExp(r'^\d+$').hasMatch(handle)) {
      _showError('Enter your numeric Telegram User ID (open @foggedvpnbot → Settings to find it).');
      return;
    }
    setState(() => _authLoading = true);
    try {
      final resp = await http.post(Uri.parse('$_apiBase/auth/request'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'telegram_handle': handle})).timeout(const Duration(seconds: 10));
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
        body: jsonEncode({'telegram_handle': _telegramHandle, 'code': code})).timeout(const Duration(seconds: 10));
      final j = jsonDecode(resp.body);
      if (j['ok'] == true && j['uuid'] != null) {
        await _secWrite('uuid', j['uuid']);
        await _secWrite('telegram_handle', _telegramHandle);
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
    await _secDelete('uuid');
    await _secDelete('telegram_handle');
    setState(() { _loggedIn = false; _uuid = ''; _servers = []; _codeRequested = false; });
  }

  // ── Subscription parsing ──

  String _mode = 'russia'; // russia, china, direct
  static const _modes = ['russia', 'china', 'direct'];

  Future<void> _fetchSubscription() async {
    if (_uuid.isEmpty) return;
    try {
      final servers = <VpnServer>[];

      // 1. Fetch VLESS/CDN from subs endpoint
      final resp = await http.get(Uri.parse('$_apiBase/subs/$_uuid?mode=$_mode')).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final decoded = utf8.decode(base64.decode(resp.body.trim()));
        for (final line in decoded.split('\n').where((l) => l.isNotEmpty)) {
          final s = _parseLine(line);
          if (s != null) servers.add(s);
        }
      } else if (resp.statusCode == 403 && resp.body.startsWith('Device limit reached')) {
        // Server's device-enforcement gate rejected us. Show a friendly dialog
        // pointing at /menu (Telegram bot) for removing a device or upgrading.
        // Keep whatever servers we had before so the UI doesn't go blank.
        _addLog('device limit: ${resp.body}');
        _showDeviceLimitDialog();
        return;
      } else if (resp.statusCode == 401 || resp.statusCode == 403) {
        _addLog('subscription error: ${resp.statusCode}');
        _showError(L.tr('expired'));
      } else {
        _addLog('subscription fetch: HTTP ${resp.statusCode}');
      }

      // 2. Fetch HY2 from singbox endpoint
      final sbResp = await http.get(Uri.parse('$_apiBase/singbox/$_uuid?mode=$_mode')).timeout(const Duration(seconds: 10));
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
        } catch (e) { debugPrint('Singbox parse error: $e'); }
      }

      // OrcaX servers come from subscription now — no hardcoded duplicates

      if (servers.isEmpty && _servers.isNotEmpty) {
        _addLog('subscription returned empty — keeping existing servers');
        return;
      }
      // DNS fallback: if subscription returned no servers and we have none cached
      if (servers.isEmpty && _servers.isEmpty) {
        _addLog('no servers from subscription — trying DNS discovery...');
        final dnsServers = await _dnsDiscoverServers();
        servers.addAll(dnsServers);
      }
      // Offline fallback: load cached servers from disk
      if (servers.isEmpty && _servers.isEmpty) {
        final cached = await _loadCachedServers();
        if (cached.isNotEmpty) {
          _addLog('loaded ${cached.length} servers from cache');
          servers.addAll(cached);
        }
      }
      if (servers.isNotEmpty) _cacheServers(servers);
      setState(() { _servers = servers; if (servers.isNotEmpty) _server = _filteredServers.isNotEmpty ? _filteredServers.first.name : servers.first.name; });
    } catch (e) {
      debugPrint('Sub fetch failed: $e');
      // Try cycling to another API endpoint and retry once
      if (await _cycleApiEndpoint()) {
        debugPrint('Retrying subscription fetch on new endpoint...');
        try {
          final servers = <VpnServer>[];
          final resp = await http.get(Uri.parse('$_apiBase/subs/$_uuid?mode=$_mode')).timeout(const Duration(seconds: 10));
          if (resp.statusCode == 200) {
            final decoded = utf8.decode(base64.decode(resp.body.trim()));
            for (final line in decoded.split('\n').where((l) => l.isNotEmpty)) {
              final s = _parseLine(line);
              if (s != null) servers.add(s);
            }
          }
          final sbResp = await http.get(Uri.parse('$_apiBase/singbox/$_uuid?mode=$_mode')).timeout(const Duration(seconds: 10));
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
            } catch (e2) { debugPrint('Singbox parse retry: $e2'); }
          }
          if (servers.isNotEmpty) {
            setState(() { _servers = servers; _server = _filteredServers.isNotEmpty ? _filteredServers.first.name : servers.first.name; });
          }
        } catch (e2) { debugPrint('Sub fetch retry also failed: $e2'); }
      }
    }
  }

  /// DNS auto-discovery: fetch encrypted server list from TXT record via multiple DoH providers
  Future<List<VpnServer>> _dnsDiscoverServers() async {
    // Try multiple DoH providers — Cloudflare, Google, Quad9
    const dohProviders = [
      'https://cloudflare-dns.com/dns-query?name=_fogged.fogged.net&type=TXT',
      'https://dns.google/resolve?name=_fogged.fogged.net&type=TXT',
      'https://dns.quad9.net:5053/dns-query?name=_fogged.fogged.net&type=TXT',
    ];
    for (final dohUrl in dohProviders) {
      try {
        final resp = await http.get(
          Uri.parse(dohUrl),
          headers: {'Accept': 'application/dns-json'},
        ).timeout(const Duration(seconds: 5));
        if (resp.statusCode != 200) continue;
        final j = jsonDecode(resp.body);
        final answers = j['Answer'] as List? ?? [];
        if (answers.isEmpty) continue;
        final encrypted = (answers.first['data'] as String?)?.replaceAll('"', '') ?? '';
        if (encrypted.isEmpty) continue;

        // Decrypt with discovery key (XOR with SHA256 of key)
        final keyBytes = sha256.convert(utf8.encode('fogged-discovery-2026-v1')).bytes;
        final encBytes = base64.decode(encrypted);
        final decBytes = List<int>.generate(encBytes.length, (i) => encBytes[i] ^ keyBytes[i % 32]);
        final payload = utf8.decode(base64.decode(utf8.decode(decBytes)));
        final servers = (jsonDecode(payload) as List).map((s) {
          final type = s['server_type'] as String? ?? 'direct';
          if (type == 'orcax') {
            return VpnServer('orcax', s['name'] ?? 'OrcaX', '${s['ip']}:${s['port']}', {'pubkey': s['pubkey'] ?? ''});
          } else if (type == 'cdn-ws') {
            return VpnServer('orcax', 'CDN ${s['name']}', '${s['ip']}:${s['port']}', {'cdn': 'true'});
          } else {
            return VpnServer('vless', s['name'] ?? 'Server', '${s['ip']}:${s['port']}', {});
          }
        }).toList();
        _addLog('DNS discovery via ${Uri.parse(dohUrl).host}: found ${servers.length} servers');
        return servers;
      } catch (e) {
        debugPrint('DoH ${Uri.parse(dohUrl).host} failed: $e');
      }
    }
    _addLog('DNS discovery failed on all providers');
    return [];
  }

  /// Persist servers to SharedPreferences for offline use
  Future<void> _cacheServers(List<VpnServer> servers) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(servers.map((s) => s.toJson()).toList());
      await prefs.setString('cached_servers_$_mode', json);
    } catch (e) { debugPrint('Cache servers: $e'); }
  }

  /// Load servers from SharedPreferences cache
  Future<List<VpnServer>> _loadCachedServers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString('cached_servers_$_mode');
      if (json == null || json.isEmpty) return [];
      final list = jsonDecode(json) as List;
      return list.map((j) => VpnServer.fromJson(j as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('Load cached servers: $e');
      return [];
    }
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
    if (_protocol == 'VLESS+Reality') return _servers.where((s) => s.protocol == 'vless').toList();
    if (_protocol == 'Hysteria2') return _servers.where((s) => s.protocol == 'hysteria2').toList();
    if (_protocol.startsWith('OrcaX')) return _servers.where((s) => s.protocol == 'orcax').toList();
    return _servers.where((s) => s.protocol == 'vless').toList();
  }

  // ── Connection ──

  Future<void> _disconnect() async {
    // Flip _connected=false BEFORE killing the proxy so the proxy.exitCode
    // handler — which races us when kill() resolves the future — sees the
    // intentional-disconnect state and skips the auto-reconnect branch.
    // Without this guard, killing in the speed-test loop or a normal user
    // disconnect spawns a stray _startProxy that fights the next iteration
    // for 127.0.0.1:1080 ("shim bind: Address already in use").
    if (mounted) setState(() { _connected = false; _connecting = false; });
    if (Platform.isAndroid) {
      await _androidVpn.invokeMethod('stopVpn');
    } else {
      _proxyProcess?.kill();
      _proxyProcess = null;
      _shimProcess?.kill();
      _shimProcess = null;
      _blackoutProcess?.kill();
      _blackoutProcess = null;
      // Kill any leftover SOCKS proxy processes on port 1080
      try {
        if (Platform.isMacOS || Platform.isLinux) {
          for (final port in ['1080', '1081']) {
            final lsof = await Process.run('lsof', ['-ti', ':$port']);
            if (lsof.exitCode == 0) {
              for (final pid in lsof.stdout.toString().trim().split('\n').where((s) => s.isNotEmpty)) {
                await Process.run('kill', ['-9', pid]);
              }
            }
          }
        } else if (Platform.isWindows) {
          for (final port in ['1080', '1081']) {
            final netstat = await Process.run('cmd', ['/c', 'netstat -ano | findstr :$port | findstr LISTENING']);
            if (netstat.exitCode == 0) {
              for (final line in netstat.stdout.toString().trim().split('\n').where((s) => s.isNotEmpty)) {
                final pid = line.trim().split(RegExp(r'\s+')).last;
                if (pid.isNotEmpty && int.tryParse(pid) != null) {
                  await Process.run('taskkill', ['/F', '/PID', pid]);
                }
              }
            }
          }
        }
      } catch (_) {}
      await _disableVpnRouting();
    }
    _cleanupTemp();
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
      if (_filteredServers.isEmpty) {
        // Empty server list almost always means the subscription fetch
        // failed (RKN routing of Cloudflare, transient API hiccup, or
        // app launched from cold offline). Try the recovery path
        // automatically once before bothering the user — re-probe API
        // endpoints + re-fetch — and retry the connect transparently.
        _addLog('empty server list — auto-refreshing before connect');
        await _probeApiAndLoad();
        if (_uuid.isNotEmpty) await _fetchSubscription();
        if (_filteredServers.isEmpty) {
          _showError('No servers available for $_protocol — tap the refresh icon in Settings, or check your connection.');
          setState(() => _connecting = false);
          return;
        }
        // Servers came back; fall through to the normal connect path.
      }
      final srv = _filteredServers.firstWhere((s) => s.name == _server, orElse: () => _filteredServers.first);
      var proto = srv.protocol;

      // Android: use native VpnService instead of Process.run
      if (Platform.isAndroid) {
        try { await _androidVpn.invokeMethod('requestNotificationPermission'); } catch (_) {}
        // VK TURN / blackout-mode chain on Android: if this server is tagged
        // transport=vkturn we pass a flag + call link through the platform
        // channel. FoggedVpnService spawns libvk_turn_client.so on localhost
        // first, then starts xray/hysteria against 127.0.0.1:9002 instead of
        // the real server IP. This is why the generated config below points
        // at 127.0.0.1:9002 when vkturn is active.
        final isVkTurn = srv.params['transport'] == 'vkturn';
        if (isVkTurn && _vkCallLink.isEmpty) {
          _showError('Whitelist is being set up. Try again in a few minutes, or pick another server.');
          setState(() => _connecting = false);
          return;
        }
        // For vkturn, xray/hysteria connect to the local vk-turn-client
        // listener rather than the real server.
        final effectiveSrv = isVkTurn
            ? VpnServer(srv.protocol, srv.name, '127.0.0.1:9002', srv.params)
            : srv;
        // Determine which binary and config to use
        String androidProto;
        String androidConfig = '';
        if (proto == 'vless') {
          androidProto = 'xray';
          androidConfig = generateXrayConfig(effectiveSrv, _uuid, _upstreamSocksPort);
        } else if (proto == 'hysteria2') {
          androidProto = 'hysteria';
          androidConfig = generateHy2Config(effectiveSrv, _uuid, _upstreamSocksPort, onWarning: _addLog);
        } else {
          androidProto = _protocol == 'OrcaX Pro Max' ? 'quic' : 'tcp';
        }
        final result = await _androidVpn.invokeMethod('startVpn', {
          'server': srv.addr, // real server — passed unchanged for logging
          'uuid': _uuid,
          'protocol': androidProto,
          'pubkey': srv.params['pubkey'] ?? '',
          'config': androidConfig,
          // Blackout-mode plumbing. Both keys empty = no VK chain.
          'vkTurn': isVkTurn,
          'vkCallLink': isVkTurn ? _vkCallLink : '',
          'vkPeer': isVkTurn ? srv.addr : '',
          'vkIsVless': isVkTurn && proto == 'vless',
          // Domain-bypass flag — FoggedVpnService applies addDisallowedApplication
          // to a hardcoded list of RU banking/gosuslugi/social apps so they
          // bypass the VPN and see the phone's real Russian IP. Platform-channel
          // arg name stays 'whitelistMode' for Android-side back-compat.
          'whitelistMode': _domainBypass,
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

      final domainBypassActive = _domainBypass || _splitDomains.isNotEmpty;

      // VK TURN chaining: if the selected server has transport=vkturn, spawn
      // vk-turn-client to tunnel traffic through VK voice-call infrastructure.
      // The server's real IP is at `srv.addr` but users actually talk to
      // vk-turn-client locally on 127.0.0.1:9002. Required during Russian
      // blackouts when only VK-whitelisted services are reachable.
      final isVkTurn = srv.params['transport'] == 'vkturn';
      if (isVkTurn) {
        // Android takes the platform-channel path above (VpnService spawns
        // libvk_turn_client.so itself), so the Dart-side desktop chain below
        // only runs on macOS / Linux / Windows.
        if (_vkCallLink.isEmpty) {
          _showError('Whitelist is being set up. Try again in a few minutes, or pick another server.');
          setState(() => _connecting = false);
          return;
        }
        final vkBin = await findVkTurnClient();
        if (vkBin == null) {
          _showError('vk-turn-client binary missing from app bundle');
          setState(() => _connecting = false);
          return;
        }
        // VLESS server → vk-turn-client VLESS mode (TCP).
        // HY2 server → vk-turn-client UDP mode.
        final peer = srv.addr; // e.g. 37.27.220.149:56000 (VLESS) or 37.27.220.149:56001 (HY2)
        final vkArgs = <String>[
          '-listen', '127.0.0.1:9002',
          '-peer', peer,
          '-vk-link', _vkCallLink,
          '-n', '3',
        ];
        if (proto == 'vless') vkArgs.add('-vless');
        // Kill any previous vk-turn-client process before spawning a new one.
        // Otherwise the new process panics with `bind: address already in use`
        // on 127.0.0.1:9002 — which our ready-detection then mis-fired on
        // because the substring "ready" matched "alREADY in use".
        if (_blackoutProcess != null) {
          _blackoutProcess!.kill();
          _blackoutProcess = null;
          await Future.delayed(const Duration(milliseconds: 250));
        }
        _addLog('Whitelist: launching vk-turn-client → VK TURN → $peer');
        _blackoutProcess = await Process.start(vkBin, vkArgs);

        // Readiness detection: the vk-turn-client's log output format has
        // changed between versions (e.g. "VLESS mode: listening" vs
        // "Established DTLS connection!"), and relying on a specific string
        // has burned real users (we'd kill a working tunnel at 90s because
        // logs didn't match). We now detect readiness via a TCP probe of
        // 127.0.0.1:9002 — the only thing that actually matters is whether
        // something is listening there. Log scanning stays for fatal-error
        // fast-fail and for captcha UI state.
        final ready = Completer<bool>();
        var hadFatalError = false;
        void scan(String l, String prefix) {
          if (!mounted) return;
          _addLog('$prefix$l');
          final lower = l.toLowerCase();
          // Fast-fail on known fatal conditions (don't wait 90s).
          if (!ready.isCompleted && (
              lower.startsWith('panic:') ||
              lower.contains('address already in use') ||
              lower.contains('fatal error:'))) {
            hadFatalError = true;
            ready.complete(false);
          }
        }
        _blackoutProcess!.stdout.transform(utf8.decoder).transform(const LineSplitter())
            .listen((l) => scan(l, 'vk-turn: '));
        _blackoutProcess!.stderr.transform(utf8.decoder).transform(const LineSplitter())
            .listen((l) => scan(l, 'vk-turn err: '));

        // Poll 127.0.0.1:9002 every 200ms. First successful connect ⇒ ready.
        // 120s ceiling (up from 90s) because manual-captcha flows routinely
        // eat 30-60s of user time before DTLS even starts.
        unawaited(() async {
          final deadline = DateTime.now().add(const Duration(seconds: 120));
          while (DateTime.now().isBefore(deadline) && !ready.isCompleted) {
            try {
              final s = await Socket.connect('127.0.0.1', 9002, timeout: const Duration(milliseconds: 500));
              await s.close();
              if (!ready.isCompleted) ready.complete(true);
              return;
            } catch (_) {
              await Future.delayed(const Duration(milliseconds: 200));
            }
          }
          if (!ready.isCompleted) ready.complete(false);
        }());

        final ok = await ready.future;
        if (!ok || hadFatalError) {
          final reason = hadFatalError
              ? 'vk-turn-client crashed (check log)'
              : 'timed out waiting for :9002 — manual captcha may have been skipped';
          _addLog('Whitelist tunnel failed: $reason');
          _blackoutProcess?.kill();
          _blackoutProcess = null;
          _showError('Whitelist tunnel failed to start — $reason');
          setState(() => _connecting = false);
          return;
        }
        _addLog('Whitelist tunnel ready (listening on 127.0.0.1:9002)');
      }

      if (proto == 'orcax') {
        binary = await findBinary('orcax-connect') ?? '';
        if (binary.isEmpty) { _showError('orcax-connect not found'); setState(() => _connecting = false); return; }
        // Pro Max = QUIC on port 9444, VLESS/HY2 = TCP on tcp_port (9446)
        // Pro Max + OrcaX HY2 → QUIC port 9444, OrcaX VLESS → TCP port 9446
        final useQuic = _protocol == 'OrcaX Pro Max' || _protocol == 'OrcaX Hysteria2';
        final serverAddr = useQuic ? srv.addr : srv.addr.replaceAll(':9444', ':${srv.params['tcp_port'] ?? '9446'}');
        args = ['--server', serverAddr, '--socks', '127.0.0.1:1080', '--uuid', _uuid];
        // Forward the subscription's `pubkey=` query param into the
        // Rust CLI. Before 2026-04-22 this was ignored by orcax-connect
        // (it used a hardcoded key derived from the server's PRIVATE key
        // — see git history for context). Passing the subscription pubkey
        // means server Reality-key rotation is now a runtime-refresh
        // operation, not a rebuild-and-ship-app operation.
        final pubkey = srv.params['pubkey'];
        if (pubkey != null && pubkey.isNotEmpty) {
          args.addAll(['--pubkey', pubkey]);
        }
        // Forward the SNI pool if the subscription carries it. Schema
        // today is implicit (SNIs rotate per-URL via fogged-sub's
        // CLIENT_SNI_POOL), so this arg is usually empty and the CLI
        // falls back to its hardcoded default. When fogged-sub starts
        // emitting `sni_pool=a,b,c,...` as a query param (P1.4
        // follow-up), the CLI will pick it up automatically via this.
        final sniPool = srv.params['sni_pool'];
        if (sniPool != null && sniPool.isNotEmpty) {
          args.addAll(['--sni-pool', sniPool]);
        }
        if (_protocol == 'OrcaX Pro Max' || _protocol == 'OrcaX Hysteria2') {
          args.addAll(['--protocol', 'quic']);
          // v4: CDN fallback URL for when QUIC is blocked (Kazakhstan, etc.)
          args.addAll(['--cdn-url', 'wss://tunnel.fogged.net']);
        }
        // Domain bypass (orcax-connect routes the hardcoded Russian-app list
        // + user's split_domains direct, rest through the tunnel).
        // --whitelist / --whitelist-extra flag names kept for Rust CLI compat.
        if (_domainBypass) args.add('--whitelist');
        if (_splitDomains.isNotEmpty) args.addAll(['--whitelist-extra', _splitDomains.join(',')]);
      } else if (proto == 'vless' || proto == 'hysteria2') {
        // sing-box (single binary handling both VLESS+Reality and Hysteria2)
        // — the same engine 3rd-party clients (Karing, Hiddify, v2raytun)
        // embed and use successfully on RU networks where our previous
        // xray + apernet/hysteria bundle hit DPI / port-hopping / TLS-pin
        // fences. Replaces two separate spawns with one.
        binary = await findSingBox() ?? '';
        if (binary.isEmpty) {
          _showError('sing-box binary not found — check installation');
          setState(() => _connecting = false);
          return;
        }
        // For vkturn servers, sing-box connects to local vk-turn-client
        // instead of the real IP (whitelist-mode VK TURN tunnel).
        final effectiveSrv = isVkTurn
            ? VpnServer(srv.protocol, srv.name, '127.0.0.1:9002', srv.params)
            : srv;
        final config = generateSingBoxConfig(effectiveSrv, _uuid, _upstreamSocksPort, onWarning: _addLog);
        final configPath = _tempPath('singbox.json');
        await File(configPath).writeAsString(config);
        args = ['run', '-c', configPath];
      } else {
        _showError('Unknown protocol: $proto'); setState(() => _connecting = false); return;
      }

      // For xray/hy2 with domain bypass on: spawn orcax-connect as a SOCKS5
      // front-end. xray/hy2 listen on 1081, the shim on 1080 decides per-
      // connection whether to tunnel or bypass.
      if (domainBypassActive && proto != 'orcax') {
        final shimBin = await findBinary('orcax-connect') ?? '';
        if (shimBin.isEmpty) {
          _addLog('WARN: orcax-connect not found — domain bypass will not work');
        } else {
          final shimArgs = <String>[
            '--socks', '127.0.0.1:1080',
            '--upstream-socks', '127.0.0.1:1081',
          ];
          if (_domainBypass) shimArgs.add('--whitelist');
          if (_splitDomains.isNotEmpty) shimArgs.addAll(['--whitelist-extra', _splitDomains.join(',')]);
          _addLog('launching whitelist shim (127.0.0.1:1080 → 1081)');
          _shimProcess = await Process.start(shimBin, shimArgs);
          _shimProcess!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
            if (mounted) _addLog('shim: $l');
          });
        }
      }

      _connectedServerIp = srv.addr.split(':').first;
      _addLog('launching $proto → ${srv.name} (${srv.addr})');
      _proxyProcess = await Process.start(binary, args);

      _proxyProcess!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
        if (!mounted) return;
        if (proto == 'orcax') {
          _handleOrcaxOutput(line);
        } else {
          _addLog(line);
          if (!_connected && (line.contains('started') || line.contains('listening') || line.contains('TCP'))) {
            await Future.delayed(const Duration(milliseconds: 500));
            if (!mounted) return;
            await _enableVpnRouting(_connectedServerIp ?? '');
            _onConnected();
          }
        }
      });

      _proxyProcess!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (!mounted) return;
        _addLog(line);
        if (!_connected && (line.contains('started') || line.contains('listening') || line.contains('TCP') || line.contains('connected'))) {
          _enableVpnRouting(_connectedServerIp ?? '');
          _onConnected();
        }
      });

      // For Xray/HY2: they don't always emit a parseable "connected" line.
      // Assume ready after 2s if the stdout/stderr keyword listeners haven't
      // fired by then. The previous `_connecting && mounted` guard skipped
      // this fallback whenever _startProxy was called outside the normal
      // toggle path (notably the speed-test loop), leaving HY2 stuck on
      // "no_listener" since hysteria's output is `INFO client mode` with
      // ANSI colors that don't match the contains() keywords.
      if (proto != 'orcax') {
        Future.delayed(const Duration(seconds: 2), () async {
          if (!_connected && mounted) {
            await _enableVpnRouting(_connectedServerIp ?? '');
            _onConnected();
          }
        });
      }

      _proxyProcess!.exitCode.then((_) async {
        if (_connected && mounted) {
          _addLog('process exited — reconnecting');
          setState(() { _connecting = true; _connected = false; });
          await _disableVpnRouting();
          await Future.delayed(const Duration(seconds: 2));
          if (mounted && _connecting) await _startProxy();
        } else {
          // Proxy died before we ever connected (xray rejected the config,
          // immediate fail, etc). Kill the shim too — otherwise it keeps
          // holding 127.0.0.1:1080 and the next Connect press hits
          // "shim bind: Address already in use".
          _shimProcess?.kill();
          _shimProcess = null;
          _blackoutProcess?.kill();
          _blackoutProcess = null;
          await _disableVpnRouting();
          if (mounted) setState(() { _connected = false; _connecting = false; });
        }
      });
    } catch (e) { setState(() => _connecting = false); _showError('$e'); }
  }

  void _onConnected() {
    if (!mounted) return;
    setState(() { _connected = true; _connecting = false; _uptime = '0:00'; });
    _trayChannel.invokeMethod('setConnected', true);
    SharedPreferences.getInstance().then((p) => p.setBool('was_connected', true));
    _startUptimeTimer();
  }

  void _handleOrcaxOutput(String line) {
    try {
      final json = jsonDecode(line) as Map<String, dynamic>;
      final status = json['status'] as String?;
      if (status == 'connected') {
        _enableVpnRouting(_connectedServerIp ?? '');
        _onConnected();
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
    if (msg.trim().isEmpty || !mounted) return;
    setState(() {
      _debugLogs.add(msg);
      if (_debugLogs.length > 300) _debugLogs.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_debugScroll.hasClients) _debugScroll.jumpTo(_debugScroll.position.maxScrollExtent);
    });
  }

  // ── Config generators ──

  /// Listen port for xray/hy2. When whitelist mode is on, they listen on 1081
  /// and the orcax-connect shim on 1080 forwards non-whitelisted traffic here.
  int get _upstreamSocksPort => (_domainBypass || _splitDomains.isNotEmpty) ? 1081 : 1080;

  // ── System proxy ──
  // Whitelist/split-tunneling lives in orcax-connect (Rust). The app just
  // tells the OS that SOCKS5 is at 127.0.0.1:1080; orcax-connect decides
  // per-connection whether to tunnel or bypass.

  String? _connectedServerIp; // for TUN route management

  Future<void> _enableVpnRouting(String serverAddr) async {
    // During the full speed test we DON'T want to flip macOS's system-wide
    // SOCKS proxy on — every other app (Apple location, Spotify, X.com,
    // browser) would get pulled into the test's proxy and dilute curl's
    // throughput measurement (saw `zero_throughput` rows when the test
    // shared the proxy with system traffic). xray still binds 127.0.0.1:1080
    // so the speed-test curl can reach it directly.
    if (_fullTesting) return;
    await _setSystemProxy(true);
  }

  Future<void> _disableVpnRouting() async {
    await _setSystemProxy(false);
  }

  Future<void> _setSystemProxy(bool enable) async {
    // Whitelist/split-tunneling is handled inside orcax-connect (SOCKS5 proxy).
    // All platforms just toggle the system SOCKS5 setting to 127.0.0.1:1080.
    try {
      if (Platform.isMacOS) {
        final r = await Process.run('networksetup', ['-listallnetworkservices']);
        final svcs = (r.stdout as String).split('\n').where((s) => s.contains('Wi-Fi') || s.contains('Ethernet')).toList();
        for (final svc in svcs) {
          final name = svc.trim();
          if (enable) {
            await Process.run('networksetup', ['-setautoproxystate', name, 'off']);
            await Process.run('networksetup', ['-setsocksfirewallproxy', name, '127.0.0.1', '1080']);
            await Process.run('networksetup', ['-setsocksfirewallproxystate', name, 'on']);
          } else {
            await Process.run('networksetup', ['-setsocksfirewallproxystate', name, 'off']);
          }
        }
      } else if (Platform.isWindows) {
        Future<bool> regRun(List<String> args) async {
          final r = await Process.run('reg', args);
          if (r.exitCode != 0) { _addLog('registry error: ${r.stderr}'); return false; }
          return true;
        }
        const regPath = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
        if (enable) {
          await regRun(['delete', regPath, '/v', 'AutoConfigURL', '/f']);
          await regRun(['add', regPath, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d', 'socks=127.0.0.1:1080', '/f']);
          await regRun(['add', regPath, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f']);
        } else {
          await regRun(['add', regPath, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
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
    } catch (e) {
      debugPrint('System proxy setup failed: $e');
      _addLog('proxy setup error: $e');
    }
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
          headers: {'Range': 'bytes=0-26214399'}).timeout(const Duration(seconds: 30));
        final elapsed = DateTime.now().difference(start);
        final bytes = resp.bodyBytes.length;
        final mbps = (bytes * 8) / (elapsed.inMilliseconds / 1000) / 1000000;
        final latencyMs = elapsed.inMilliseconds > 0 ? (elapsed.inMilliseconds * 0.1).round() : 0;
        if (mounted) setState(() { _testing = false; _testResult = '${mbps.toStringAsFixed(1)} Mbps | ${latencyMs}ms | ${_fmtBytes(bytes)} in ${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s'; });
      } else {
      // Desktop: use curl through SOCKS proxy
      final devNull = Platform.isWindows ? 'NUL' : '/dev/null';
      final result = await Process.run('curl', [
        '-x', 'socks5h://127.0.0.1:1080', '-so', devNull,
        '-w', '%{speed_download}|%{size_download}|%{time_total}|%{time_starttransfer}',
        '-r', '0-26214399', 'https://hel1-speed.hetzner.com/100MB.bin', '--max-time', '30',
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
    // Hide technical details from regular users in the SHORT summary;
    // the dialog still shows the full message so admins can copy/report it.
    final summary = (_userRole == 'admin' || _userRole == 'supermod') ? msg
        : msg.contains('ProcessException') ? L.tr('failed')
        : msg.contains('curl') ? L.tr('failed')
        : msg.contains('No such file') ? L.tr('failed')
        : msg.length > 200 ? '${msg.substring(0, 200)}…' : msg;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _ErrorDialog(
        summary: summary,
        fullMessage: msg,
        recentLogs: _debugLogs.length > 50
            ? _debugLogs.sublist(_debugLogs.length - 50).join('\n')
            : _debugLogs.join('\n'),
        appVersion: _appVersion,
        platform: Platform.operatingSystem,
        uuid: _uuid,
        apiBase: _apiBase,
      ),
    );
  }
  void _showMsg(String msg) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3))); }

  /// Shown when the server's device-enforcement gate returns 403 on /subs or
  /// /singbox. Distinct from the "expired" dialog so the user understands it's
  /// a tier-limit issue, not an expired subscription. Offers @foggedvpn_bot
  /// as the channel to remove a device or upgrade.
  void _showDeviceLimitDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: Text(L.tr('device_limit_title')),
        content: Text(L.tr('device_limit_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(L.tr('close')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              launchUrl(Uri.parse('https://t.me/foggedvpn_bot'), mode: LaunchMode.externalApplication);
            },
            child: Text(L.tr('device_limit_upgrade')),
          ),
        ],
      ),
    );
  }
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
                if (_downloaded != '0 B') _statChip(L.tr('downloaded'), _downloaded),
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
      mode: _mode, onLogout: _logout, domainBypass: _domainBypass,
      onDomainBypassChanged: (v) async {
        setState(() => _domainBypass = v);
        final prefs = await SharedPreferences.getInstance();
        // Pref key stays 'whitelist_mode' for back-compat with existing users
        // and with the cloud-settings JSON schema.
        await prefs.setBool('whitelist_mode', v);
        // The --whitelist flag is baked into orcax-connect args at launch,
        // so a toggle change while connected needs a quick reconnect.
        if (_connected) {
          await _disconnect();
          await Future.delayed(const Duration(milliseconds: 300));
          await _startProxy();
        }
      },
      splitDomains: _splitDomains,
      onSplitDomainsChanged: (domains) async {
        setState(() => _splitDomains = domains);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList('split_domains', domains);
        if (_connected) {
          await _disconnect();
          await Future.delayed(const Duration(milliseconds: 300));
          await _startProxy();
        }
      },
      deviceLimit: _deviceLimit,
      devicesUsed: _devicesUsed,
      subTier: _subTier,
      onCheckForUpdates: _checkForUpdateForced,
      onRefreshSubscription: () async {
        // User-triggered "I think my servers are stale" — re-probe the
        // API endpoint chain (in case dl.fogged.net is RKN-blocked on
        // their carrier and a fallback worker is up) and re-fetch the
        // server list. Replaces the "delete and re-add the profile"
        // workaround that doesn't apply to an integrated app.
        _addLog('manual subscription refresh triggered');
        await _probeApiAndLoad();
        if (_uuid.isNotEmpty) await _fetchSubscription();
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
          if (!_fullTesting) GestureDetector(
            onTap: _runFullSpeedTest,
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
              child: Text(L.tr('run_full_test'), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600))),
          ),
          if (_fullTesting) ...[
            Text('${L.tr('testing_progress')} $_fullTestProgress/$_fullTestTotal',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () { setState(() => _fullTestCancel = true); _addLog('speed test: cancel requested'); },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.15),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(L.tr('stop'),
                  style: TextStyle(color: Colors.red.shade300, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 16),

        if (!_connected && _fullTestResults.isEmpty)
          Center(child: Padding(padding: const EdgeInsets.only(top: 60),
            child: Text(L.tr('tap_test_all_hint'), style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 13), textAlign: TextAlign.center)))
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
            // Action row: Copy + Send to dev (shown only after the run finishes).
            if (!_fullTesting) Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: _formatSpeedReportPublic()));
                    _showMsg(L.tr('copied'));
                  },
                  child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(border: Border.all(color: Colors.white.withValues(alpha: 0.15)), borderRadius: BorderRadius.circular(6)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.copy, size: 12, color: Colors.white.withValues(alpha: 0.6)),
                      const SizedBox(width: 4),
                      Text(L.tr('copy'), style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 11)),
                    ])),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _sendSpeedReportToDev,
                  child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(border: Border.all(color: Colors.white.withValues(alpha: 0.15)), borderRadius: BorderRadius.circular(6)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.send, size: 12, color: Colors.white.withValues(alpha: 0.6)),
                      const SizedBox(width: 4),
                      Text(L.tr('send_to_dev'), style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 11)),
                    ])),
                ),
              ]),
            ),
            Expanded(child: ListView.builder(
              itemCount: _fullTestResults.length,
              itemBuilder: (_, i) {
                final r = _fullTestResults[i];
                final isBest = i == 0 && !_fullTesting && r['speed'] != null;
                final failed = !_fullTesting && r['status'] == 'failed';
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: isBest ? Colors.green.withValues(alpha: 0.08)
                        : failed ? Colors.red.withValues(alpha: 0.05)
                        : Colors.white.withValues(alpha: 0.02),
                    border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)))),
                  child: Row(children: [
                    if (isBest) Padding(padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.star, size: 12, color: Colors.green.shade300)),
                    if (failed) Padding(padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.error_outline, size: 12, color: Colors.red.shade300)),
                    Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(r['protocol'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                      Text(r['server'] ?? '', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 10)),
                    ])),
                    Expanded(flex: 2, child: Text(
                      r['speed'] != null ? '${(r['speed'] as double).toStringAsFixed(1)} Mbps'
                        : r['status'] == 'testing' ? '...'
                        : r['status'] == 'cancelled' ? L.tr('cancelled')
                        : failed ? L.tr('failed')
                        : '--',
                      style: TextStyle(
                        color: r['speed'] != null ? Colors.white
                          : r['status'] == 'cancelled' ? Colors.white.withValues(alpha: 0.4)
                          : failed ? Colors.red.shade300 : Colors.white30,
                        fontSize: 12, fontWeight: FontWeight.w600),
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
    if (_fullTesting) return;
    if (_servers.isEmpty) { _showError(L.tr('no_servers_yet') ); return; }

    // Build list of all protocol+server combos.
    // Whitelist (transport=vkturn) servers are intentionally excluded —
    // they're for blackout-mode fallback where the connection takes
    // 30-60s through VK voice infrastructure and requires re-doing the
    // VK auth + captcha for each test, which VK rate-limits as bot
    // activity after the first run. Speed isn't the right benchmark for
    // them anyway (connectivity is).
    final combos = <Map<String, String>>[];
    for (final proto in _protocols) {
      final servers = (proto == 'VLESS+Reality' ? _servers.where((s) => s.protocol == 'vless')
          : proto == 'Hysteria2' ? _servers.where((s) => s.protocol == 'hysteria2')
          : _servers.where((s) => s.protocol == 'orcax'))
          .where((s) => s.params['transport'] != 'vkturn');
      for (final srv in servers) {
        combos.add({
          'protocol': proto,
          'server': srv.name,
          'addr': srv.addr,
          'sni': srv.params['sni'] ?? '',
        });
      }
    }
    if (combos.isEmpty) return;

    // Speed test temporarily disables the orcax-connect domain-bypass shim
    // so each combo is measured against the raw protocol path (matching how
    // 3rd-party clients like Karing/Hiddify connect — they have no shim).
    // The shim's TCP-only SOCKS5 forwarder doesn't carry HY2's UDP-associate
    // SOCKS5 dance through cleanly, which masks otherwise-working HY2 +
    // ТЕСТ servers as "probe_failed" in the test even though those same
    // servers connect fine on mobile / 3rd-party clients.
    final savedDomainBypass = _domainBypass;
    _domainBypass = false;
    // Disconnect current, then test each combo
    await _disconnect();
    setState(() {
      _fullTesting = true;
      _fullTestCancel = false;
      _fullTestProgress = 0;
      _fullTestTotal = combos.length;
      _fullTestResults = combos.map((c) => <String, dynamic>{
        'protocol': c['protocol'],
        'server': c['server'],
        'sni': c['sni'],
        'speed': null,
        'latency': null,
        'status': 'pending',
      }).toList();
    });

    for (int i = 0; i < combos.length; i++) {
      // Honour the Stop button — break before starting a new combo, mark
      // any not-yet-run rows as cancelled so the UI shows them clearly
      // instead of staying on "pending".
      if (_fullTestCancel) {
        for (var j = i; j < combos.length; j++) {
          if (mounted && _fullTestResults[j]['status'] == 'pending') {
            setState(() => _fullTestResults[j]['status'] = 'cancelled');
          }
        }
        break;
      }
      setState(() { _fullTestProgress = i + 1; _fullTestResults[i]['status'] = 'testing'; });

      final combo = combos[i];
      _protocol = combo['protocol']!;
      _server = combo['server']!;

      // Wrap the whole combo in a wall-clock budget so a hung connect (e.g.
      // a server reachable only from inside RU) can't stall the rest of the
      // queue. 35s = up to 6s connect/wait + 10s probe + 15s curl + headroom.
      // Earlier 25s budget with 4s connect-wait wasn't enough for HY2 from
      // RU paths: the QUIC INITIAL roundtrip + server's HTTP auth callback
      // to Supabase + reply takes 3-5s real-world (the same Karing-on-RU
      // flow that "just works" gives hysteria ~10s before its retry/timeout
      // fires). Status ALWAYS lands on done|failed so the row never displays
      // "--" stuck on 'testing' state.
      try {
        await Future(() async {
          await _startProxy();
          await Future.delayed(const Duration(seconds: 6));
          if (!_connected) throw 'no_listener';
          // Quick upstream probe — _connected only means the local SOCKS
          // port is up, not that the tunnel actually carries traffic. 10s
          // for the 204-byte fetch covers worst-case RU→relay→exit→gstatic
          // round trips when the QUIC stream's first packet has to nail
          // a slow path through RKN-throttled UDP.
          final probe = await Process.run('curl', [
            '-x', 'socks5h://127.0.0.1:1080', '-so', Platform.isWindows ? 'NUL' : '/dev/null',
            '-w', '%{http_code}',
            'https://www.gstatic.com/generate_204', '--max-time', '10',
          ]);
          if (probe.exitCode != 0) throw 'probe_failed';
          final result = await Process.run('curl', [
            '-x', 'socks5h://127.0.0.1:1080', '-so', Platform.isWindows ? 'NUL' : '/dev/null',
            '-w', '%{speed_download}|%{time_starttransfer}',
            '-r', '0-26214399', 'https://hel1-speed.hetzner.com/100MB.bin', '--max-time', '15',
          ]);
          final parts = result.stdout.toString().split('|');
          if (parts.length < 2) throw 'curl_no_output';
          final speedBps = double.tryParse(parts[0]) ?? 0;
          final ttfb = double.tryParse(parts[1]) ?? 0;
          final mbps = (speedBps * 8) / 1000000;
          if (mbps <= 0) throw 'zero_throughput';
          setState(() {
            _fullTestResults[i]['speed'] = mbps;
            _fullTestResults[i]['latency'] = (ttfb * 1000).round();
            _fullTestResults[i]['status'] = 'done';
          });
        }).timeout(const Duration(seconds: 35));
      } catch (e) {
        if (mounted) setState(() {
          _fullTestResults[i]['status'] = 'failed';
          _fullTestResults[i]['error'] = e.toString();
        });
        _addLog('speed: ${combo['protocol']}/${combo['server']} failed — $e');
      }

      await _disconnect();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // Restore the user's domain-bypass setting that we forced off above.
    _domainBypass = savedDomainBypass;
    // Sort by speed descending
    _fullTestResults.sort((a, b) => ((b['speed'] as double?) ?? 0).compareTo((a['speed'] as double?) ?? 0));
    setState(() => _fullTesting = false);

    // Report results to backend (privacy-preserving)
    _reportSpeedTests();

    // Run SNI test too
    _runSniTest();
  }

  /// Public-safe speed report for the Copy button. Strips SNIs, internal
  /// error codes, and UUID — users paste these into chats / Telegram /
  /// support tickets and we don't want competitors or RKN data-mining the
  /// SNI rotation list out of leaked screenshots.
  String _formatSpeedReportPublic() {
    final buf = StringBuffer();
    buf.writeln('Fogged Speed Report');
    buf.writeln('app: $_appVersion ${Platform.operatingSystem}  region: $_mode');
    buf.writeln('---');
    for (final r in _fullTestResults) {
      final speed = r['speed'] != null ? '${(r['speed'] as double).toStringAsFixed(1)} Mbps' : 'FAILED';
      final lat = r['latency'] != null ? '  ${r['latency']}ms' : '';
      buf.writeln('[${r['protocol']}] ${r['server']}');
      buf.writeln('  $speed$lat');
    }
    return buf.toString();
  }

  /// Internal report posted only to the support endpoint. Includes the
  /// per-row SNI and the internal error code so the dev side can tell
  /// which SNI / which failure mode is degraded for this user. Never
  /// shown in the UI, never copied to clipboard.
  String _formatSpeedReportInternal() {
    final buf = StringBuffer();
    buf.writeln('Fogged Speed Report (internal)');
    buf.writeln('app: $_appVersion ${Platform.operatingSystem}');
    buf.writeln('region: $_mode  uuid: $_uuid');
    buf.writeln('date: ${DateTime.now().toIso8601String()}');
    buf.writeln('---');
    for (final r in _fullTestResults) {
      final speed = r['speed'] != null ? '${(r['speed'] as double).toStringAsFixed(1)} Mbps' : '—';
      final lat = r['latency'] != null ? '${r['latency']}ms' : '—';
      final status = r['status'] ?? '?';
      final err = r['error'] != null ? '  err=${r['error']}' : '';
      final sni = (r['sni'] as String?) ?? '';
      buf.writeln('[${r['protocol']}] ${r['server']}');
      buf.writeln('  status=$status  speed=$speed  ttfb=$lat  sni=$sni$err');
    }
    return buf.toString();
  }

  Future<void> _sendSpeedReportToDev() async {
    try {
      await http.post(Uri.parse('$_apiBase/support/create'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uuid': _uuid, 'message': _formatSpeedReportInternal()})).timeout(const Duration(seconds: 10));
      _showMsg(L.tr('report_sent'));
    } catch (e) {
      _showMsg('Error: $e');
    }
  }

  Future<void> _reportSpeedTests() async {
    try {
      final results = _fullTestResults.where((r) => r['speed'] != null).map((r) => {
        'protocol': r['protocol'], 'server': r['server'], 'speed_mbps': r['speed'], 'latency_ms': r['latency'],
      }).toList();
      await http.post(Uri.parse('$_apiBase/speedtest/report'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uuid': _uuid, 'region': _mode, 'results': results})).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> _runSniTest() async {
    setState(() { _sniResults = []; });
    try {
      // Fetch SNI list from API
      final resp = await http.get(Uri.parse('$_apiBase/sni/list')).timeout(const Duration(seconds: 10));
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
            '-so', Platform.isWindows ? 'NUL' : '/dev/null', '-w', '%{time_connect}', '--max-time', '5',
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
    // Report SNI results to backend
    try {
      await http.post(Uri.parse('$_apiBase/sni/report'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uuid': _uuid, 'country': _mode, 'results': _sniResults.map((r) => {
          'sni': r['sni'], 'latency_ms': r['latency'], 'status': r['status'],
        }).toList()})).timeout(const Duration(seconds: 10));
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
          if (_siteResults.isNotEmpty) GestureDetector(
            onTap: () {
              final blocked = _siteResults.where((r) => r['working'] == false).map((r) => r['site']).join('\n');
              final working = _siteResults.where((r) => r['working'] == true).map((r) => r['site']).join('\n');
              final text = 'Blocked:\n$blocked\n\nWorking:\n$working';
              Clipboard.setData(ClipboardData(text: text));
              _showMsg('Copied');
            },
            child: Padding(padding: const EdgeInsets.only(right: 8),
              child: Icon(Icons.copy, size: 14, color: Colors.white.withValues(alpha: 0.3))),
          ),
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
      final resp = await http.get(Uri.parse('$_apiBase/blocked/stats')).timeout(const Duration(seconds: 10));
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
            '-x', 'socks5h://127.0.0.1:1080', '-so', Platform.isWindows ? 'NUL' : '/dev/null',
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
        }).toList()})).timeout(const Duration(seconds: 10));
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
        TextField(controller: _handleCtl,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(hintText: 'User ID', hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2)),
            prefixIcon: Icon(Icons.person, color: Colors.white.withValues(alpha: 0.3), size: 18),
            filled: true, fillColor: Colors.white.withValues(alpha: 0.05),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1))))),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.info_outline, size: 13, color: Colors.white.withValues(alpha: 0.3)),
          const SizedBox(width: 6),
          Flexible(child: Text(L.tr('userid_help'), style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.35), height: 1.4))),
        ]),
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
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
          decoration: InputDecoration(hintText: '00000000', hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.15), letterSpacing: 8),
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
