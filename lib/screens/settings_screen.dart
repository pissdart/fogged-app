part of '../main.dart';

// Settings screen: account, referrals, whitelist, split tunnel, beta,
// auto-start, support form, language switcher, legal links, update-check.
// Owned state stays small (_supportCtl, _domainCtl, a couple of flags);
// everything else is passed in via widget fields from _HomeScreenState.

class _SettingsScreen extends StatefulWidget {
  final String accountNumber, subStatus, subEndsAt, daysLeft, referralCode, userRole, uuid, apiBase, protocol, server, mode, subTier;
  final double referralEarnings;
  final int totalReferrals;
  final int deviceLimit;
  final int? devicesUsed;
  final List<String> debugLogs;
  final VoidCallback onLogout;
  // Russian app domain bypass — lets Sber/Tinkoff/Gosuslugi etc. skip the
  // foreign VPN exit. Different from the VK TURN "Whitelist Mode" server
  // archetype, which is activated by selecting a vkturn-transport server.
  final bool domainBypass;
  final ValueChanged<bool> onDomainBypassChanged;
  final List<String> splitDomains;
  final ValueChanged<List<String>> onSplitDomainsChanged;
  /// Triggered by the "Check for updates" button. Always shows a popup —
  /// the update prompt itself if newer is available, or an "up-to-date" /
  /// error status dialog matching the update-prompt's visual style.
  final Future<void> Function() onCheckForUpdates;
  /// Re-probe API endpoints + re-fetch the subscription. User-triggered
  /// equivalent of "delete and re-add the profile" from third-party
  /// clients — needed when the cached server list went stale (RKN
  /// rotated a server IP, our region filter changed, etc.) and the
  /// app's idle 5-min refresh hasn't fired yet.
  final Future<void> Function() onRefreshSubscription;

  const _SettingsScreen({
    required this.accountNumber, required this.subStatus, required this.subEndsAt,
    required this.daysLeft, required this.referralCode, required this.referralEarnings,
    required this.totalReferrals, required this.userRole, required this.uuid,
    required this.apiBase, required this.debugLogs, required this.protocol,
    required this.server, required this.mode, required this.onLogout,
    required this.domainBypass, required this.onDomainBypassChanged,
    required this.splitDomains, required this.onSplitDomainsChanged,
    required this.deviceLimit, required this.devicesUsed, required this.subTier,
    required this.onCheckForUpdates,
    required this.onRefreshSubscription,
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

  @override
  void initState() {
    super.initState();
    _loadSystemPrefs();
  }

  Future<void> _loadSystemPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoStart = prefs.getBool('auto_start') ?? false;
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

  /// Persist the toggle state and wire the OS-level auto-start
  /// mechanism for the current platform. Each platform has a different
  /// hook:
  ///   macOS   — `~/Library/LaunchAgents/net.fogged.vpn.plist`
  ///   Linux   — `~/.config/autostart/fogged.desktop` (XDG autostart)
  ///   Windows — `HKCU\…\Run\FoggedVPN` registry value (via native
  ///             method-channel; installer.iss seeds the same key at
  ///             install time, this runtime path keeps it in sync)
  ///   Android — `BootReceiver` handles the actual boot intent. We
  ///             only persist the pref here; the receiver reads it on
  ///             `BOOT_COMPLETED` and starts FoggedVpnService.
  ///
  /// `auto_start` SharedPreferences flag is the single source of truth
  /// — every platform gates on it, plus the cold-boot-after-update
  /// path in main.dart's `_loadAuth` reads it as a recovery signal.
  Future<void> _setAutoStart(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_start', enabled);
    setState(() => _autoStart = enabled);

    if (Platform.isMacOS) {
      await _setAutoStartMacOS(enabled);
    } else if (Platform.isLinux) {
      await _setAutoStartLinux(enabled);
    } else if (Platform.isWindows) {
      await _setAutoStartWindows(enabled);
    }
    // Android: pref only — BootReceiver reads it asynchronously when
    // the system fires BOOT_COMPLETED.
  }

  Future<void> _setAutoStartMacOS(bool enabled) async {
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

  Future<void> _setAutoStartLinux(bool enabled) async {
    // XDG Autostart spec: any .desktop file in ~/.config/autostart/
    // gets launched on session start across GNOME, KDE, XFCE, MATE,
    // Cinnamon. No systemd-user fallback needed; XDG covers them all.
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return;
    final dir = Directory('$home/.config/autostart');
    final file = File('${dir.path}/fogged.desktop');
    if (enabled) {
      await dir.create(recursive: true);
      final exec = Platform.resolvedExecutable;
      await file.writeAsString('''[Desktop Entry]
Type=Application
Name=Fogged VPN
Exec=$exec
X-GNOME-Autostart-enabled=true
NoDisplay=false
Terminal=false
''');
    } else {
      try { await file.delete(); } catch (_) {}
    }
  }

  Future<void> _setAutoStartWindows(bool enabled) async {
    // Calls into windows/runner/flutter_window.cpp which writes/deletes
    // HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run
    // (key name: "FoggedVPN"). The Inno Setup installer at
    // installer.iss:43-54 writes the same key at install time so
    // first-time auto-start works even before the user opens settings.
    try {
      await const MethodChannel('com.fogged.vpn/windows')
        .invokeMethod('setAutoStart', {'enabled': enabled});
    } catch (e) {
      debugPrint('windows setAutoStart failed: $e');
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
            if (widget.subTier.isNotEmpty) _infoRow('Tier', widget.subTier),
            _infoRow('Status', widget.subStatus.isEmpty ? '--' : widget.subStatus),
            _infoRow(L.tr('subscription'), widget.daysLeft == '?' ? '--' : '${widget.daysLeft} ${L.tr('days_left')}'),
            if (widget.subEndsAt.isNotEmpty) _infoRow(L.tr('expired'), widget.subEndsAt.split('T').first),
            if (widget.deviceLimit > 0) _infoRow(
              'Devices',
              // Corporate tier (150) is uncapped on the server side
              // (see orcax-core connection_cap_for_devices) — render
              // ∞ in the UI so marketing + enforcement agree.
              (widget.subTier.toLowerCase() == 'corporate' || widget.deviceLimit >= 150)
                ? (widget.devicesUsed == null ? '—  /  ∞' : '${widget.devicesUsed}  /  ∞')
                : (widget.devicesUsed == null
                    ? '—  /  ${widget.deviceLimit}'
                    : '${widget.devicesUsed}  /  ${widget.deviceLimit}'),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: SizedBox(height: 40, child: ElevatedButton(
              onPressed: () => launchUrl(Uri.parse('https://t.me/foggedvpnbot'), mode: LaunchMode.externalApplication),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.08), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              child: Text(L.tr('subscribe'), style: const TextStyle(fontSize: 13, letterSpacing: 1)),
            ))),
            const SizedBox(width: 8),
            // Refresh subscription — re-probes API endpoints + re-fetches
            // the server list. The self-recovery path for "I can't connect
            // and don't know why" — replaces the support-ticket pattern
            // of "delete and re-add the profile" which doesn't apply to
            // an integrated app.
            SizedBox(width: 56, height: 40, child: _RefreshSubButton(onTap: widget.onRefreshSubscription)),
          ]),
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

          // Domain-bypass: client-side routing of Russian apps direct,
          // skipping the VPN. Has nothing to do with the VK-TURN
          // "Whitelist" server which is selected from the server picker
          // — the old "Whitelist Mode" label was a long-running source
          // of confusion (see git log for the rename).
          _sectionTitle(L.tr('domain_bypass_section')),
          Container(
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withValues(alpha: 0.08))),
            child: Column(children: [
              SwitchListTile(
                value: widget.domainBypass,
                onChanged: widget.onDomainBypassChanged,
                title: Text(L.tr('domain_bypass_toggle'), style: const TextStyle(color: Colors.white, fontSize: 13)),
                subtitle: Text(L.tr('domain_bypass_subtitle'), style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11)),
                activeColor: Colors.white,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
              ),
              if (widget.domainBypass) Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(L.tr('domain_bypass_list_label'),
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1)),
                  const SizedBox(height: 6),
                  Text(L.tr('domain_bypass_list_preview'),
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11, height: 1.5)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 20),

          // Split tunnel (custom bypass domains).
          // Desktop only — on Android the per-domain shim isn't bundled
          // (orcax-connect isn't cross-compiled for arm64-v8a yet) and
          // VpnService can only do per-app bypass natively. Show users a
          // pointer at the OS-level setting instead of a UI that
          // silently drops their input. Restoring this on Android is a
          // v1.7 task (see plan: ship orcax-connect as a .so + rewire
          // tun2socks to point at its SOCKS port).
          _sectionTitle(L.tr('split_tunnel')),
          if (Platform.isAndroid)
            Container(
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withValues(alpha: 0.08))),
              padding: const EdgeInsets.all(14),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.info_outline, size: 16, color: Colors.white.withValues(alpha: 0.4)),
                const SizedBox(width: 10),
                Expanded(child: Text(L.tr('split_tunnel_android_note'),
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12, height: 1.4))),
              ]),
            )
          else
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
                onChanged: (v) => _setAutoStart(v),
                title: Text(L.tr('auto_start_title'), style: const TextStyle(color: Colors.white, fontSize: 13)),
                subtitle: Text(L.tr('auto_start_subtitle'), style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11)),
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

          // Legal links
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            GestureDetector(
              onTap: () => launchUrl(Uri.parse('https://fogged.net/privacy-policy.html'), mode: LaunchMode.externalApplication),
              child: Text(L.tr('privacy_policy'), style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.3), decoration: TextDecoration.underline, decorationColor: Colors.white.withValues(alpha: 0.2))),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('|', style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.15))),
            ),
            GestureDetector(
              onTap: () => launchUrl(Uri.parse('https://fogged.net/user-agreement.html'), mode: LaunchMode.externalApplication),
              child: Text(L.tr('terms_of_service'), style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.3), decoration: TextDecoration.underline, decorationColor: Colors.white.withValues(alpha: 0.2))),
            ),
          ]),
          const SizedBox(height: 16),

          // Check for updates / repair button. Result rendered as a popup
          // matching the update-dialog visual style (handled in main.dart).
          Center(child: SizedBox(width: double.infinity, height: 36, child: ElevatedButton.icon(
            onPressed: widget.onCheckForUpdates,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.06), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            icon: Icon(Icons.refresh, size: 14, color: Colors.white.withValues(alpha: 0.5)),
            label: Text(L.tr('check_updates'), style: const TextStyle(fontSize: 12, letterSpacing: 0.5)),
          ))),
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
        body: jsonEncode({'uuid': widget.uuid, 'message': body})).timeout(const Duration(seconds: 10));
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

/// Small icon-button next to "Subscribe" that re-fetches the server
/// list. Replaces the "delete and re-add the profile" workaround that
/// only applies to third-party clients (Hiddify/Karing). For our app
/// it's the same effect with one tap and no logout.
class _RefreshSubButton extends StatefulWidget {
  final Future<void> Function() onTap;
  const _RefreshSubButton({required this.onTap});
  @override
  State<_RefreshSubButton> createState() => _RefreshSubButtonState();
}

class _RefreshSubButtonState extends State<_RefreshSubButton> {
  bool _busy = false;

  Future<void> _go() async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await widget.onTap(); }
    catch (_) { /* surfaced via _addLog inside the caller */ }
    if (mounted) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server list refreshed'), duration: Duration(seconds: 2)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ElevatedButton(
    onPressed: _busy ? null : _go,
    style: ElevatedButton.styleFrom(
      backgroundColor: Colors.white.withValues(alpha: 0.08),
      foregroundColor: Colors.white,
      padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    child: _busy
      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))
      : const Icon(Icons.refresh, size: 18),
  );
}
