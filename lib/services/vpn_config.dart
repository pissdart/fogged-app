// Pure helpers for VPN config generation + platform binary discovery.
// Extracted from _HomeScreenState so the god-widget is smaller and the
// pieces that can be unit-tested aren't buried in 2200 LOC of widget state.
//
// - `generateXrayConfig`  — Xray JSON for VLESS+Reality tunnels
// - `generateHy2Config`   — Hysteria2 YAML
// - `findBinary`          — platform-aware path lookup (bundle, dev tree, PATH)
// - `findVkTurnClient`    — same, for the multi-platform vk-turn-client shims
// - `isArm64`             — shells out to `uname -m`; used to pick macOS binaries

import 'dart:convert';
import 'dart:io';

import '../models/vpn_server.dart';

String generateXrayConfig(VpnServer srv, String uuid, int socksPort) {
  final parts = srv.addr.split(':');
  final ip = parts[0];
  final port = parts.length > 1 ? parts[1] : '8443';
  final pbk = srv.params['pbk'] ?? '';
  final sid = srv.params['sid'] ?? '';
  final sni = srv.params['sni'] ?? 'cdn.jsdelivr.net';
  // The OV/ТЕСТ server explicitly emits `flow=""` because OrcaX VLESS
  // doesn't speak Vision yet. Xray's parser rejects an empty `"flow":""`
  // string ("flow doesn't support 'none'"), so omit the field entirely
  // when the server didn't request a flow. params['flow'] is null when
  // missing from the URL, "" when present-but-empty.
  final flowParam = srv.params['flow'];
  final flow = flowParam ?? 'xtls-rprx-vision';
  final fp = srv.params['fp'] ?? 'random';
  final user = <String, dynamic>{"id": uuid, "encryption": "none"};
  if (flow.isNotEmpty) user["flow"] = flow;
  return jsonEncode({
    "log": {"loglevel": "warning"},
    "inbounds": [{"tag": "socks", "protocol": "socks", "listen": "127.0.0.1", "port": socksPort,
      "settings": {"auth": "noauth", "udp": true}}],
    "outbounds": [{"tag": "proxy", "protocol": "vless", "settings": {
      "vnext": [{"address": ip, "port": int.tryParse(port) ?? 8443,
        "users": [user]}]},
      "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"serverName": sni, "fingerprint": fp,
          "publicKey": pbk, "shortId": sid}}}]
  });
}

String generateHy2Config(VpnServer srv, String uuid, int socksPort, {void Function(String)? onWarning}) {
  final parts = srv.addr.split(':');
  final ip = parts[0];
  final port = parts.length > 1 ? parts[1] : '20000-50000';
  final obfs = srv.params['obfs-password'] ?? srv.params['obfs'] ?? '';
  if (obfs.isEmpty && onWarning != null) {
    onWarning('WARNING: no obfs password from server, HY2 may fail');
  }
  return '''
server: $ip:$port
auth: $uuid
obfs:
  type: salamander
  salamander:
    password: $obfs
socks5:
  listen: 127.0.0.1:$socksPort
tls:
  insecure: true
''';
}

Future<String?> findBinary(String name) async {
  final ext = Platform.isWindows ? '.exe' : '';
  final binName = '$name$ext';

  // App bundle directory (where the executable lives)
  final appDir = File(Platform.resolvedExecutable).parent.path;

  final paths = <String>[];
  if (Platform.isWindows) {
    paths.addAll([
      '$appDir\\$binName',                                          // next to app exe
      '$appDir\\bin\\$binName',                                     // app/bin/
      '${Platform.environment['LOCALAPPDATA']}\\Fogged\\bin\\$binName',
      '${Directory.current.path}\\$binName',
      'C:\\Program Files\\Fogged\\$binName',
    ]);
  } else if (Platform.isMacOS) {
    // Inside .app bundle: Fogged.app/Contents/MacOS/
    paths.addAll([
      '$appDir/$binName',                                           // next to app exe in bundle
      '${File(Platform.resolvedExecutable).parent.parent.path}/Resources/$binName', // .app/Contents/Resources/
      '/usr/local/bin/$binName',
    ]);
  } else {
    paths.addAll([
      '$appDir/$binName',
      '/usr/local/bin/$binName',
    ]);
  }

  // Dev paths (only check if running from source tree)
  if (appDir.contains('CascadeProjects') || appDir.contains('flutter')) {
    paths.addAll([
      '${Directory.current.path}/orcax/bin/$binName',
      '${Directory.current.path}/orcax/target/release/$binName',
      '${Directory.current.path}/orcax/target/debug/$binName',
    ]);
  }

  for (final p in paths) { if (await File(p).exists()) return p; }
  return null;
}

/// Find the platform-specific vk-turn-client binary.
/// We ship 5 variants: darwin-arm64, darwin-amd64, linux-amd64,
/// windows-amd64.exe, android-arm64.
Future<String?> findVkTurnClient() async {
  String name;
  if (Platform.isMacOS) {
    name = isArm64() ? 'vk-turn-client-darwin-arm64' : 'vk-turn-client-darwin-amd64';
  } else if (Platform.isWindows) {
    name = 'vk-turn-client-windows-amd64.exe';
  } else if (Platform.isAndroid) {
    name = 'vk-turn-client-android-arm64';
  } else {
    name = 'vk-turn-client-linux-amd64';
  }
  return findBinary(name);
}

bool isArm64() {
  final r = Process.runSync('uname', ['-m']);
  return r.stdout.toString().trim() == 'arm64';
}
