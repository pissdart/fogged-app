part of '../main.dart';

/// Dialog-style error popup matching `_UpdateDialog` look. Shows a compact
/// summary, with Copy / Send Report / Close actions. "Send Report" forwards
/// the full error + last 50 log lines to the support endpoint so it lands
/// in the bot's admin chat for diagnosis. Disabled if user isn't logged in
/// (no UUID), since the support endpoint is per-user.
class _ErrorDialog extends StatefulWidget {
  final String summary;
  final String fullMessage;
  final String recentLogs;
  final String appVersion;
  final String platform;
  final String uuid;
  final String apiBase;
  const _ErrorDialog({
    required this.summary,
    required this.fullMessage,
    required this.recentLogs,
    required this.appVersion,
    required this.platform,
    required this.uuid,
    required this.apiBase,
  });

  @override
  State<_ErrorDialog> createState() => _ErrorDialogState();
}

class _ErrorDialogState extends State<_ErrorDialog> {
  String _reportStatus = '';
  bool _reporting = false;

  String _buildReportPayload() {
    return 'ERROR REPORT\n'
        '─────────────\n'
        'App: Fogged v${widget.appVersion} (${widget.platform})\n'
        'UUID: ${widget.uuid.isEmpty ? "(not logged in)" : widget.uuid}\n'
        '─────────────\n'
        'Error:\n${widget.fullMessage}\n'
        '─────────────\n'
        'Recent logs:\n${widget.recentLogs}';
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _buildReportPayload()));
    if (mounted) setState(() => _reportStatus = 'Copied to clipboard');
  }

  Future<void> _sendReport() async {
    if (widget.uuid.isEmpty) {
      setState(() => _reportStatus = 'Log in first to send reports');
      return;
    }
    setState(() { _reporting = true; _reportStatus = 'Sending…'; });
    try {
      final resp = await http.post(
        Uri.parse('${widget.apiBase}/support/create'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uuid': widget.uuid, 'message': _buildReportPayload()}),
      ).timeout(const Duration(seconds: 15));
      if (mounted) {
        setState(() {
          _reporting = false;
          _reportStatus = resp.statusCode == 200
              ? 'Sent to admin ✓'
              : 'Send failed (${resp.statusCode})';
        });
      }
    } catch (e) {
      if (mounted) setState(() { _reporting = false; _reportStatus = 'Send failed: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0A0A0A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Container(
        width: 360, padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.error_outline, color: Colors.red.shade300, size: 22),
            const SizedBox(width: 8),
            const Text('Error', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 1)),
          ]),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: SelectableText(
              widget.summary,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12, height: 1.45),
            ),
          ),
          if (_reportStatus.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_reportStatus, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11)),
          ],
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            GestureDetector(
              onTap: _copy,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(border: Border.all(color: Colors.white.withValues(alpha: 0.1)), borderRadius: BorderRadius.circular(8)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.copy, size: 13, color: Colors.white.withValues(alpha: 0.5)),
                  const SizedBox(width: 6),
                  Text('Copy', style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12)),
                ]),
              ),
            ),
            GestureDetector(
              onTap: _reporting ? null : _sendReport,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(border: Border.all(color: Colors.white.withValues(alpha: 0.1)), borderRadius: BorderRadius.circular(8)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (_reporting)
                    const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
                  else
                    Icon(Icons.send, size: 13, color: Colors.white.withValues(alpha: 0.5)),
                  const SizedBox(width: 6),
                  Text('Send Report', style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12)),
                ]),
              ),
            ),
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                child: const Text('Close', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
