class VpnServer {
  final String protocol; // 'vless', 'hysteria2', 'orcax'
  final String name;
  final String addr; // ip:port
  final Map<String, String> params; // pbk, sid, sni, flow, obfs, etc.
  VpnServer(this.protocol, this.name, this.addr, this.params);

  Map<String, dynamic> toJson() => {
    'protocol': protocol,
    'name': name,
    'addr': addr,
    'params': params,
  };

  factory VpnServer.fromJson(Map<String, dynamic> j) => VpnServer(
    j['protocol'] as String? ?? 'vless',
    j['name'] as String? ?? 'Server',
    j['addr'] as String? ?? '',
    (j['params'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v.toString())) ?? {},
  );
}
