class VpnServer {
  final String protocol; // 'vless', 'hysteria2', 'orcax'
  final String name;
  final String addr; // ip:port
  final Map<String, String> params; // pbk, sid, sni, flow, obfs, etc.
  VpnServer(this.protocol, this.name, this.addr, this.params);
}
