part of '../main.dart';

// In-app update dialog (Surfshark-style). Downloads + verifies SHA256 +
// installs per-platform: macOS uses a detached shell helper to swap the
// bundle after exit; Windows runs the installer silently; Android hands
// the APK to the system package installer. See main.dart for the trigger
// path (update-check in _HomeScreenState).

/// Status popup shown when the user manually clicks "Check for updates"
/// and there's nothing newer to install (or the check failed). Visual
/// style matches _UpdateDialog so the manual + auto flows feel unified.
class _UpdateStatusDialog extends StatelessWidget {
  final String title;
  final String body;
  final VoidCallback onClose;
  const _UpdateStatusDialog({required this.title, required this.body, required this.onClose});

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
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 2)),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11, height: 1.4)),
          ],
          const SizedBox(height: 16),
          GestureDetector(
            onTap: onClose,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
              decoration: BoxDecoration(border: Border.all(color: Colors.white.withValues(alpha: 0.1)), borderRadius: BorderRadius.circular(8)),
              child: Text(L.tr('close'), style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
            ),
          ),
        ]),
      ),
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  final String version, notes, downloadUrl, expectedHash;
  final VoidCallback onSkip, onLater;
  const _UpdateDialog({required this.version, required this.notes, required this.downloadUrl, this.expectedHash = '', required this.onSkip, required this.onLater});

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
                  child: Text(L.tr('close'), style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12)),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _installUpdate,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: Text(L.tr('restart'), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
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

      // Verify SHA256 hash if server provided one
      if (widget.expectedHash.isNotEmpty) {
        final digest = sha256.convert(bytes);
        if (digest.toString() != widget.expectedHash) {
          setState(() { _downloading = false; _status = 'Download corrupted — hash mismatch'; });
          debugPrint('SHA256 mismatch: expected ${widget.expectedHash}, got $digest');
          return;
        }
        debugPrint('SHA256 verified: $digest');
      }

      setState(() { _status = 'Installing...'; _progress = 1.0; });

      if (Platform.isMacOS) {
        // Save ZIP → extract → hand the new .app off to a detached helper
        // script that (1) waits for US to exit so the running bundle releases
        // its file locks, (2) swaps /Applications/Fogged.app, (3) strips the
        // quarantine xattr so Gatekeeper doesn't re-challenge, (4) relaunches.
        // Doing rm+cp in-process fails with EPERM because Fogged is still
        // holding open fds on its own Mach-O binary.
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
          // Find the .app inside (safe: no shell invocation)
          String? appPath;
          await for (final entity in Directory(extractDir).list(recursive: true)) {
            if (entity is Directory && entity.path.endsWith('.app')) {
              appPath = entity.path;
              break;
            }
          }
          if (appPath != null && appPath.isNotEmpty) {
            // Mark this version as installed so we don't re-prompt on relaunch.
            final p = await SharedPreferences.getInstance();
            await p.setString('update_installed_version', widget.version);
            setState(() => _status = 'Updating...');

            final myPid = pid;
            final updaterScript = '${Directory.systemTemp.path}/fogged-updater-${DateTime.now().millisecondsSinceEpoch}.sh';
            // Shell-quote the extracted app path so spaces don't break cp.
            final quotedNewApp = "'${appPath.replaceAll("'", "'\\''")}'";
            await File(updaterScript).writeAsString(
              '#!/bin/bash\n'
              '# Fogged macOS updater — runs detached after parent exit.\n'
              'set +e\n'
              '# 1. Wait for the running Fogged process to exit (bounded, 30s).\n'
              'for _ in \$(seq 1 60); do\n'
              '  if ! kill -0 $myPid 2>/dev/null; then break; fi\n'
              '  sleep 0.5\n'
              'done\n'
              '# Extra belt-and-braces: kill any stragglers named Fogged.\n'
              'while pgrep -x "Fogged" > /dev/null 2>&1; do sleep 0.5; done\n'
              'sleep 1\n'
              '# 2. Swap the bundle. rm may partial-fail if user has another\n'
              '#    copy open — cp handles that by overwriting what it can.\n'
              'rm -rf "/Applications/Fogged.app"\n'
              'cp -R $quotedNewApp "/Applications/Fogged.app"\n'
              'if [ ! -d "/Applications/Fogged.app" ]; then\n'
              '  # Install path not writable (user installed to ~/Applications?\n'
              '  # or is on a read-only volume). Fall back to ~/Applications.\n'
              '  mkdir -p "\$HOME/Applications"\n'
              '  cp -R $quotedNewApp "\$HOME/Applications/Fogged.app"\n'
              '  APP_TARGET="\$HOME/Applications/Fogged.app"\n'
              'else\n'
              '  APP_TARGET="/Applications/Fogged.app"\n'
              'fi\n'
              '# 3. Strip quarantine so Gatekeeper doesn\'t re-challenge.\n'
              'xattr -rd com.apple.quarantine "\$APP_TARGET" 2>/dev/null || true\n'
              '# 4. Relaunch.\n'
              'open "\$APP_TARGET"\n'
              '# 5. Cleanup.\n'
              'rm -f "$zipPath"\n'
              'rm -rf "$extractDir"\n'
              'rm -f "\$0"\n'
            );
            await Process.run('chmod', ['+x', updaterScript]);
            // Detach so the script survives us.
            await Process.start(updaterScript, [], mode: ProcessStartMode.detached);
            await Future.delayed(const Duration(milliseconds: 500));
            exit(0);
          }
        }
        // Cleanup on failure (couldn't find .app in zip, or unzip failed)
        try { await File(zipPath).delete(); } catch (_) {}
        try { await Directory(extractDir).delete(recursive: true); } catch (_) {}
        setState(() => _status = 'Install failed — download ok, extraction empty');
      } else if (Platform.isWindows) {
        final exePath = '${Platform.environment['TEMP']}\\Fogged-Setup.exe';
        await File(exePath).writeAsBytes(bytes);
        setState(() => _status = 'Running installer...');
        final result = await Process.run(exePath, ['/S']);
        // Only mark as installed if installer succeeded
        if (result.exitCode == 0) {
          final p = await SharedPreferences.getInstance();
          await p.setString('update_installed_version', widget.version);
        }
        await Future.delayed(const Duration(seconds: 2));
        exit(0);
      } else if (Platform.isAndroid) {
        // Save APK and trigger Android package installer
        final dir = Directory('/storage/emulated/0/Download');
        final apkPath = '${dir.path}/Fogged-Update.apk';
        await File(apkPath).writeAsBytes(bytes);
        setState(() => _status = 'Opening installer...');
        final p = await SharedPreferences.getInstance();
        await p.setString('update_installed_version', widget.version);
        // Use platform channel to trigger install intent
        const channel = MethodChannel('com.fogged.vpn/android');
        await channel.invokeMethod('installApk', apkPath);
      }
    } catch (e) {
      setState(() { _downloading = false; _status = 'Error: $e'; });
    }
  }
}
