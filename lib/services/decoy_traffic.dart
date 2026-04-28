// Decoy traffic generator — runs while the tunnel is up, periodically
// fetches a random benign URL through the local SOCKS5 proxy that fronts
// the active VPN. The point is to defeat traffic-correlation attacks
// (e.g. RKN logs your VPN exit IP transferring 5 MB at time T, and
// matches it to a known YouTube video by byte/timing fingerprint). With
// decoys layered in, the same logs see your VPN exit doing extra
// uncorrelated activity that doesn't match any single content
// fingerprint — the per-flow signal-to-noise drops sharply.
//
// Properties:
//   * Goes through 127.0.0.1:<socks> (the same proxy the system is
//     configured to use), so the bytes ride the encrypted tunnel and
//     emerge from the same exit IP as real traffic. A decoy that
//     bypassed the tunnel would be useless — adversary would see the
//     decoy URL hit directly from the user's home IP.
//   * Curated URL pool of 30+ legitimate, varied-size, no-auth public
//     endpoints. Random selection per fire — the pool is large enough
//     that an adversary can't easily identify "this is a Fogged
//     decoy".
//   * Random User-Agent rotation per request — no UA-based
//     fingerprint of "decoy traffic from Fogged".
//   * Jittered 30-90 s intervals between fires — looks like real
//     browser tab activity, not a periodic beacon.
//   * Best-effort: any error (network, proxy, target down) is
//     swallowed silently. Decoy is supplementary; tunnel correctness
//     is unaffected.
//   * Bandwidth cost: ~50-200 KB/min average. Negligible against the
//     real traffic the user is generating.
//
// Protocol-agnostic: applies identically to OV (TCP) and OrcaX Pro Max
// (QUIC) since both expose the same SOCKS5 listener. The decoy doesn't
// know or care which transport carries it.

import 'dart:async';
import 'dart:io';
import 'dart:math';

class DecoyTrafficService {
  static const List<String> _urls = [
    // News (mixed sizes, no auth)
    'https://www.bbc.com',
    'https://www.theguardian.com',
    'https://www.reuters.com/world/',
    'https://news.ycombinator.com',
    'https://www.theverge.com',
    'https://arstechnica.com',
    'https://www.theatlantic.com',
    'https://www.cnn.com',

    // Tech / dev
    'https://github.com',
    'https://stackoverflow.com',
    'https://docs.python.org/3/',
    'https://nodejs.org/en/docs/',
    'https://crates.io',
    'https://www.npmjs.com',
    'https://developer.mozilla.org/en-US/docs/Web/HTML',

    // Knowledge
    'https://en.wikipedia.org/wiki/Special:Random',
    'https://commons.wikimedia.org/wiki/Special:Random',
    'https://www.wikipedia.org',

    // Random JSON (small, varied)
    'https://api.github.com/zen',
    'https://api.github.com/octocat',
    'https://api.coindesk.com/v1/bpi/currentprice.json',
    'https://httpbin.org/uuid',
    'https://httpbin.org/bytes/4096',
    'https://httpbin.org/bytes/16384',

    // Search engine landing
    'https://duckduckgo.com',
    'https://www.bing.com',

    // Misc
    'https://www.reddit.com/.json',
    'https://www.imdb.com',
    'https://www.python.org',
  ];

  static const List<String> _userAgents = [
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:122.0) Gecko/20100101 Firefox/122.0',
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1',
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Mobile Safari/537.36',
  ];

  Timer? _timer;
  final Random _rng = Random.secure();
  bool _running = false;
  int _socksPort = 1080;
  // Min/max delay between fires (seconds). Default 30-90 s mimics a
  // user with several tabs open who clicks/scrolls every minute or so.
  final int _minDelaySec;
  final int _maxDelaySec;
  void Function(String message)? onLog;

  DecoyTrafficService({int minDelaySec = 30, int maxDelaySec = 90})
      : _minDelaySec = minDelaySec,
        _maxDelaySec = maxDelaySec;

  bool get isRunning => _running;

  /// Begin firing decoys through `127.0.0.1:<socksPort>`. Idempotent —
  /// calling start while already running is a no-op.
  void start({int socksPort = 1080}) {
    if (_running) return;
    _running = true;
    _socksPort = socksPort;
    _scheduleNext();
  }

  /// Cancel the timer and stop firing. Calling stop while not running
  /// is a no-op.
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleNext() {
    if (!_running) return;
    final span = _maxDelaySec - _minDelaySec;
    final delay = Duration(seconds: _minDelaySec + (span > 0 ? _rng.nextInt(span) : 0));
    _timer = Timer(delay, () async {
      if (!_running) return;
      await _fireOne();
      _scheduleNext();
    });
  }

  Future<void> _fireOne() async {
    final url = _urls[_rng.nextInt(_urls.length)];
    final ua = _userAgents[_rng.nextInt(_userAgents.length)];
    try {
      // socks5h:// resolves DNS through the proxy too — without the `h`
      // the local OS resolver leaks the destination hostname even when
      // the body rides the tunnel.
      final result = await Process.run('curl', [
        '-s',
        '-o', '/dev/null',
        '-w', '%{size_download}',
        '--max-time', '10',
        '-x', 'socks5h://127.0.0.1:$_socksPort',
        '-H', 'User-Agent: $ua',
        '-H', 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        '-H', 'Accept-Language: en-US,en;q=0.5',
        '-H', 'Accept-Encoding: gzip, deflate, br',
        '-H', 'DNT: 1',
        '-H', 'Connection: keep-alive',
        url,
      ]).timeout(const Duration(seconds: 12));
      if (result.exitCode == 0 && onLog != null) {
        final host = Uri.tryParse(url)?.host ?? url;
        onLog!('decoy $host → ${result.stdout}b');
      }
    } catch (_) {
      // Best-effort — silently skip on any failure.
    }
  }
}
