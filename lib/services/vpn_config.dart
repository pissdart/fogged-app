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

/// Sing-box config for VLESS+Reality OR Hysteria2 — same engine 3rd-party
/// mobile clients (Karing, Hiddify, v2raytun) embed and use successfully on
/// the same RU networks where our previous xray + apernet/hysteria bundle
/// hit DPI / port-hopping / TLS-pin fence. Single binary handling both
/// protocols replaces two separate generators (xray JSON, hysteria YAML)
/// with one JSON schema.
///
/// `srv.protocol` is `'vless'` or `'hysteria2'`; we map to the right
/// outbound type. Single SOCKS5 inbound on `socksPort`.
String generateSingBoxConfig(VpnServer srv, String uuid, int socksPort, {void Function(String)? onWarning}) {
  final parts = srv.addr.split(':');
  final ip = parts[0];
  final rawPort = parts.length > 1 ? parts[1] : '';
  // Hy2 URLs may carry a port-range (`38000-43999`); sing-box wants a single
  // int. Take the first port — sing-box's hysteria2 doesn't port-hop per
  // packet anyway (matches what worked in v1.6.18 with the apernet binary).
  final firstPort = rawPort.contains('-') ? rawPort.split('-').first : rawPort;

  Map<String, dynamic> outbound;
  if (srv.protocol == 'vless') {
    final pbk = srv.params['pbk'] ?? '';
    final sid = srv.params['sid'] ?? '';
    final sni = srv.params['sni'] ?? 'cdn.jsdelivr.net';
    final fp = srv.params['fp'] ?? 'random';
    final flowParam = srv.params['flow'];
    final flow = flowParam ?? 'xtls-rprx-vision';
    outbound = {
      'type': 'vless',
      'tag': 'proxy',
      'server': ip,
      'server_port': int.tryParse(firstPort) ?? 8443,
      'uuid': uuid,
      // OV/ТЕСТ explicitly empties flow (no Vision); sing-box accepts the
      // omitted-when-empty pattern just like our v1.6.9 xray fix.
      if (flow.isNotEmpty) 'flow': flow,
      'tls': {
        'enabled': true,
        'server_name': sni,
        'reality': {
          'enabled': true,
          'public_key': pbk,
          'short_id': sid,
        },
        'utls': {'enabled': true, 'fingerprint': fp},
      },
    };
  } else if (srv.protocol == 'hysteria2') {
    final obfs = srv.params['obfs-password'] ?? srv.params['obfs'] ?? '';
    final sni = srv.params['sni'] ?? 'bing.com';
    if (obfs.isEmpty && onWarning != null) {
      onWarning('WARNING: no obfs password from server, HY2 may fail');
    }
    outbound = {
      'type': 'hysteria2',
      'tag': 'proxy',
      'server': ip,
      'server_port': int.tryParse(firstPort) ?? 38000,
      'password': uuid,
      if (obfs.isNotEmpty) 'obfs': {'type': 'salamander', 'password': obfs},
      'tls': {
        'enabled': true,
        'server_name': sni,
        'insecure': true,
      },
    };
  } else {
    throw 'unsupported protocol for sing-box: ${srv.protocol}';
  }

  return jsonEncode({
    'log': {'level': 'warn'},
    'inbounds': [
      {
        'type': 'socks',
        'tag': 'socks-in',
        'listen': '127.0.0.1',
        'listen_port': socksPort,
      }
    ],
    'outbounds': [outbound],
  });
}

String generateHy2Config(VpnServer srv, String uuid, int socksPort, {void Function(String)? onWarning}) {
  final parts = srv.addr.split(':');
  final ip = parts[0];
  // Match what sing-box (the underlying engine in Karing/Hiddify/v2raytun)
  // actually does on the wire when consuming a hysteria2:// URL with a
  // port range: connect to a single port for the whole session, ignore
  // the per-packet hopping that apernet/hysteria does by default.
  // apernet/hysteria's port-hopping orphans response packets on macOS's
  // stateful UDP NAT (each new dest-port looks like a new flow) so the
  // client never sees the server's reply — Pro Max single-port :9446
  // works fine from the same machine, confirming UDP egress is healthy.
  // Server URL still advertises the full range so a future hopping-aware
  // client could opt in.
  final portRange = parts.length > 1 ? parts[1] : '20000-50000';
  final port = portRange.contains('-') ? portRange.split('-').first : portRange;
  final obfs = srv.params['obfs-password'] ?? srv.params['obfs'] ?? '';
  // Server's masquerade.proxy.url is bing.com — without an explicit SNI on
  // the client, hysteria sent the literal IP as TLS server_name, which RKN
  // DPI flags and stalls the QUIC handshake. /singbox already emits
  // "server_name":"bing.com"; mirror that here.
  final sni = srv.params['sni'] ?? 'bing.com';
  // pinSHA256 is in every hysteria2:// URL we emit. Without using it the
  // client falls back to `insecure: true` and accepts any cert silently —
  // when the russia-relay path delivers a different cert than expected the
  // handshake hangs without a clear error. Pinning gives an explicit
  // verify-or-fail with the right cert, no silent accept.
  final pinSha256 = srv.params['pinSHA256'] ?? srv.params['pin_sha256'] ?? '';
  if (obfs.isEmpty && onWarning != null) {
    onWarning('WARNING: no obfs password from server, HY2 may fail');
  }
  // bandwidth.up/down — without these hysteria's BBR initializes its
  // congestion window very conservatively and the QUIC INITIAL roundtrip
  // through the russia-relay UDP NAT times out before BBR widens. Karing's
  // sing-box defaults these; we have to do the same. Numbers are
  // advertised-cap, not actual — server ignores values it can't honor.
  final bandwidthBlock = '''
bandwidth:
  up: 100 mbps
  down: 100 mbps''';
  final tlsBlock = pinSha256.isEmpty
      ? '''tls:
  sni: $sni
  insecure: true'''
      : '''tls:
  sni: $sni
  pinSHA256: $pinSha256''';
  return '''
server: $ip:$port
auth: $uuid
$bandwidthBlock
obfs:
  type: salamander
  salamander:
    password: $obfs
socks5:
  listen: 127.0.0.1:$socksPort
$tlsBlock
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

/// Find the platform-specific sing-box binary. Bundle ships both macOS
/// architectures so M1/M2/M3 and Intel Macs both work; CI ships windows
/// + linux + android variants for those targets.
Future<String?> findSingBox() async {
  String name;
  if (Platform.isMacOS) {
    name = isArm64() ? 'sing-box-darwin-arm64' : 'sing-box-darwin-amd64';
  } else if (Platform.isWindows) {
    name = 'sing-box-windows-amd64.exe';
  } else if (Platform.isAndroid) {
    name = 'sing-box-android-arm64';
  } else {
    name = 'sing-box-linux-amd64';
  }
  return findBinary(name);
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
