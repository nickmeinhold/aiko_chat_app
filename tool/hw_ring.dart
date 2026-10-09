// Android ring hardware harness — the one PR #210 (design 22) was verified with on
// a Pixel 4 against enspyr, 2026-10-08.
//
//   dart run tool/hw_ring.dart ring             # alive → mint → cold → invite → rang?
//   dart run tool/hw_ring.dart ring --island    # the same, but the ISLAND sends the wake
//   dart run tool/hw_ring.dart tap Answer --shade
//   dart run tool/hw_ring.dart island 1m        # the join proof: a video-token mint
//   dart run tool/hw_ring.dart end <call>
//
// WHY THIS EXISTS. Each of these traps cost a wrong reading before it was found,
// and each is now a step the harness takes rather than a thing to remember:
//
//   1. SILENCE IS NOT A RESULT until the handset is online. The first "the push did
//      nothing" was the Pixel off the network. `ring` runs `alive` first and stops.
//   2. OVERLAP THE INVITE WITH THE WAKE. `ring_probe.py invite` blocks ~7s on its
//      ack; running it and THEN the FCM push produced a 10.2s-stale invite that
//      `admitRing` (10s freshness) correctly refused. The real island wakes in the
//      same second it persists, so `invite` starts the signed send and fires the
//      wake 1.5s later. A refused-stale ring here is a harness artifact; the same
//      failure in the field is claude-tasks#4233.
//   3. HOME, THEN `am kill`. On a foreground app `am kill` is a silent no-op and
//      the "cold start" was warm. `cold` fails if a pid survives.
//   4. EXPAND THE SHADE BEFORE `uiautomator dump`. Notification actions are absent
//      from the dump while the shade is collapsed: `tap Answer --shade`.
//
// WHO SENDS THE WAKE. By default the harness sends the FCM wake itself
// (tool/fcm_push.py, straight from this machine) — a RECEIVER test that needs no
// island sender. `--island` sends only the signed invite/end and lets the island's
// own FCM path wake the handset — the END-TO-END test. The 2026-10-08 run was the
// former and was briefly reported as the latter (island tab, 2026-10-09): enspyr
// had no FCM credential at the time. Every result line says which one it was.
//
// And one the bash original had: it sent both halves of `invite` to /dev/null, so
// a failed signed send or a rejected FCM push still printed "pushed". Here every
// child is awaited and a non-zero exit fails the command, with its log kept.
//
// Needs: adb with one device; ~/.claude/.env providing RING_HOST, RING_A_USER,
// RING_A_PASS (the caller) and FCM creds for tool/fcm_push.py; `ssh enspyr` with
// passwordless `sudo -n docker` for `island`. The handset's FCM token comes from the
// island DB (devices row for the callee): export FCM_TOKEN or write it to
// $HW_STATE/fcm_token.txt.
import 'dart:async';
import 'dart:io';

const _pkg = 'cc.imagineering.aiko_chat_app';
const _defaultChannel = '01M46EANYZ253Z04Y9XR8K4PAV'; // nicka <-> ringtest DM, enspyr
const _wakeLag = Duration(milliseconds: 1500);

final String _repo = File.fromUri(Platform.script).parent.parent.path;
final Map<String, String> _env = {..._dotenv(), ...Platform.environment};
final Directory _state = Directory(
  _env['HW_STATE'] ?? '${Directory.systemTemp.path}/aiko-hw-ring',
)..createSync(recursive: true);
final String _channel = _env['RING_CHANNEL'] ?? _defaultChannel;

/// A step that failed in a way the operator must see — never a silent "pushed".
class HarnessFailure implements Exception {
  HarnessFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) return _usage();
  final viaIsland = args.contains('--island');
  final rest = args.sublist(1).where((a) => a != '--island').toList();
  try {
    switch (args.first) {
      case 'ring':
        await ring(rest.isEmpty ? null : rest.first, viaIsland: viaIsland);
      case 'alive':
        await alive();
      case 'mint':
        stdout.writeln(await mint());
      case 'cold':
        await cold();
      case 'invite':
        await invite(rest.isEmpty ? await mint() : rest.first, viaIsland: viaIsland);
      case 'wake':
        await _fcm('invite', _need(rest, 'call id'));
      case 'end':
        await end(_need(rest, 'call id'), viaIsland: viaIsland);
      case 'endwake':
        await _fcm('end', _need(rest, 'call id'));
      case 'waitlog':
        final secs = rest.length > 1 ? int.parse(rest[1]) : 25;
        stdout.writeln(await waitLog(RegExp(_need(rest, 'regex')), Duration(seconds: secs)));
      case 'tap':
        await tap(_need(rest, 'label'), shade: rest.contains('--shade'));
      case 'notifs':
        stdout.writeln(await notifs());
      case 'focus':
        stdout.writeln(await focus());
      case 'island':
        stdout.writeln(await island(rest.isEmpty ? '2m' : rest.first));
      default:
        return _usage();
    }
  } on HarnessFailure catch (e) {
    stderr.writeln('hw_ring: $e');
    exitCode = 1;
  }
}

/// The whole cold+locked ring in one command: the four traps in order, ending at
/// the device's own word that it rang this exact call.
Future<void> ring(String? callId, {bool viaIsland = false}) async {
  await alive();
  final call = callId ?? await mint();
  await cold();
  await _run('adb', ['logcat', '-c']);
  final sent = _clock();
  await invite(call, viaIsland: viaIsland);
  // The island's wake can trail the signed send by FCM latency (measured up to
  // 14s), so its window is wider than the harness's own overlapped wake.
  final within = Duration(seconds: viaIsland ? 40 : 25);
  final line = await waitLog(RegExp('ring: c=\\S+ m=$call'), within);
  stdout.writeln('RANG $call — wake sent by ${_sender(viaIsland)}, invite at $sent\n  $line\n'
      'next: tap Answer --shade | tap Decline --shade | end $call${viaIsland ? ' --island' : ''}'
      '${viaIsland ? '\nthen ask the island tab to read its log from $sent ("fcm sent", android_ready)' : ''}');
}

String _sender(bool viaIsland) => viaIsland ? 'the ISLAND (end-to-end)' : 'this machine (receiver test)';

/// Trap 1: the handset must reach the network before silence means anything.
Future<void> alive() async {
  final r = await Process.run('adb', ['shell', 'ping', '-c', '1', '-W', '3', '8.8.8.8']);
  if (r.exitCode != 0) {
    throw HarnessFailure('handset OFFLINE (or no adb device) — fix that before reading any result');
  }
  stdout.writeln('alive: online');
}

/// One minting rule for the whole harness: ring_probe.py's own.
Future<String> mint() async {
  final out = await _run('python3', [
    '-c',
    "import importlib.util,sys;sys.argv=['x'];"
        "s=importlib.util.spec_from_file_location('r','tool/ring_probe.py');"
        'm=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(m.mint_call_id())',
  ]);
  return out.trim();
}

/// Trap 3: Home first, or `am kill` does nothing.
Future<void> cold() async {
  await _run('adb', ['shell', 'input', 'keyevent', '3']);
  await Future<void>.delayed(const Duration(seconds: 2));
  await _run('adb', ['shell', 'am', 'kill', _pkg]);
  await Future<void>.delayed(const Duration(seconds: 1));
  final pid = (await Process.run('adb', ['shell', 'pidof', _pkg])).stdout.toString().trim();
  if (pid.isNotEmpty) throw HarnessFailure('cold: pid $pid survived am kill — not a cold start');
  stdout.writeln('cold: no process');
}

/// Trap 2: the signed invite and the wake overlap, in the island's order.
/// With [viaIsland] only the signed message goes out and the island wakes.
Future<void> invite(String call, {bool viaIsland = false}) => _signAndWake('invite', call, viaIsland);

Future<void> end(String call, {bool viaIsland = false}) => _signAndWake('end', call, viaIsland);

Future<void> _signAndWake(String verb, String call, bool viaIsland) async {
  final signed = _probe(verb, call);
  if (!viaIsland) {
    await Future<void>.delayed(_wakeLag);
    await _fcm(verb, call);
  }
  await signed;
  stdout.writeln('$verb $call: signed; wake sent by ${_sender(viaIsland)}');
}

/// Wait for an AikoRing logcat line; returns it.
Future<String> waitLog(RegExp pattern, Duration within) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    final out = await _run('adb', ['logcat', '-d', '-s', 'AikoRing']);
    for (final line in out.split('\n').reversed) {
      if (pattern.hasMatch(line)) return line.trim();
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw HarnessFailure('no AikoRing line matching /${pattern.pattern}/ within ${within.inSeconds}s');
}

/// Trap 4: tap a node by text/content-desc; expand the shade first for actions.
Future<void> tap(String label, {bool shade = false}) async {
  if (shade) {
    await _run('adb', ['shell', 'cmd', 'statusbar', 'expand-notifications']);
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  final node = RegExp(
    '<node [^>]*?(?:text|content-desc)="${RegExp.escape(label)}"'
    r'[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
    caseSensitive: false,
  );
  for (var i = 0; i < 10; i++) {
    await Process.run('adb', ['shell', 'uiautomator', 'dump', '/sdcard/ui.xml']);
    final xml = (await Process.run('adb', ['shell', 'cat', '/sdcard/ui.xml'])).stdout.toString();
    final m = node.firstMatch(xml);
    if (m != null) {
      final b = [for (var g = 1; g <= 4; g++) int.parse(m.group(g)!)];
      final x = (b[0] + b[2]) ~/ 2, y = (b[1] + b[3]) ~/ 2;
      await _run('adb', ['shell', 'input', 'tap', '$x', '$y']);
      stdout.writeln('tapped $label at $x,$y ${_clock()}');
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw HarnessFailure('tap $label: NOT FOUND${shade ? '' : ' (notification action? add --shade)'}');
}

Future<int> notifs() async {
  final out = await _run('adb', ['shell', 'dumpsys', 'notification']);
  return RegExp('NotificationRecord\\(.*${RegExp.escape(_pkg)}').allMatches(out).length;
}

Future<String> focus() async {
  final out = await _run('adb', ['shell', 'dumpsys', 'window']);
  final line = out.split('\n').firstWhere((l) => l.contains('mCurrentFocus'), orElse: () => '');
  return line.replaceFirst(RegExp(r'.*u0 '), '').trim();
}

/// The join proof: a video-token mint for the callee means the call joined.
Future<String> island(String since) async {
  final out = await _run('ssh', [
    '-o', 'ConnectTimeout=10', 'enspyr',
    'sudo -n docker logs --timestamps --since $since aiko-chat-island-1 2>&1',
  ]);
  final hits = out
      .split('\n')
      .where((l) => l.contains('video-token') || l.contains('ws connected'))
      .map((l) => l.replaceAll(RegExp(r'token=[^ "]+'), 'token=…'))
      .toList();
  return hits.skip(hits.length > 6 ? hits.length - 6 : 0).join('\n');
}

// --- children -----------------------------------------------------------------

Future<void> _probe(String verb, String call) => _run(
      'python3',
      ['tool/ring_probe.py', verb, call],
      env: {
        'AIKO_HOST': _need1('RING_HOST'),
        'RING_USER': _need1('RING_A_USER'),
        'RING_PASS': _need1('RING_A_PASS'),
        'RING_CHANNEL': _channel,
      },
      log: '$verb-$call.probe.log',
    );

Future<void> _fcm(String verb, String call) => _run(
      'python3',
      ['tool/fcm_push.py', verb, '--token', _token(), '--channel', _channel, '--call', call],
      log: '$verb-$call.fcm.log',
    );

/// Run a child in the repo; its output is kept in [log] (under $HW_STATE) when
/// named, and a non-zero exit is a [HarnessFailure] that points at that log.
Future<String> _run(String exe, List<String> args, {Map<String, String>? env, String? log}) async {
  final r = await Process.run(exe, args, workingDirectory: _repo, environment: {..._env, ...?env});
  final out = '${r.stdout}${r.stderr}';
  final path = log == null ? null : '${_state.path}/$log';
  if (path != null) File(path).writeAsStringSync(out);
  if (r.exitCode != 0) {
    throw HarnessFailure('${[exe, ...args.take(2)].join(' ')} exited ${r.exitCode}'
        '${path != null ? ' — see $path' : ':\n$out'}');
  }
  return r.stdout.toString();
}

String _token() {
  final t = _env['FCM_TOKEN'] ?? _readOrNull('${_state.path}/fcm_token.txt');
  if (t == null || t.trim().isEmpty) {
    throw HarnessFailure('no FCM token — export FCM_TOKEN or write ${_state.path}/fcm_token.txt');
  }
  return t.trim();
}

String _need1(String key) =>
    _env[key] ?? (throw HarnessFailure('$key unset — expected in ~/.claude/.env'));

String _need(List<String> rest, String what) =>
    rest.isNotEmpty ? rest.first : (throw HarnessFailure('missing $what'));

String? _readOrNull(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync() : null;
}

/// `KEY=value` lines from ~/.claude/.env (quotes stripped, `export ` tolerated).
Map<String, String> _dotenv() {
  final text = _readOrNull('${Platform.environment['HOME']}/.claude/.env');
  if (text == null) return {};
  final line = RegExp(r'''^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$''');
  return {
    for (final m in text.split('\n').map(line.firstMatch).whereType<RegExpMatch>())
      m.group(1)!: m.group(2)!.trim().replaceAll(RegExp(r'''^["']|["']$'''), ''),
  };
}

String _clock() => DateTime.now().toIso8601String().substring(11, 19);

void _usage() {
  stderr.writeln('usage: dart run tool/hw_ring.dart '
      '<ring [call] [--island]|alive|mint|cold|invite [call] [--island]|wake call|end call [--island]|endwake call|'
      'waitlog regex [secs]|tap label [--shade]|notifs|focus|island [since]>');
  exitCode = 64;
}
