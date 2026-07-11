import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../network/network_status.dart';
import 'error_report.dart';

/// A "Report a problem" action shown beneath an auth error banner. Tapping it
/// gathers device specs + the current [NetworkStatus] + the raw error into a
/// plain-text bundle and opens the platform share sheet — so a stuck user can
/// hand a maintainer everything needed to reproduce, in one tap.
///
/// The collect + share seams are provider-injected ([diagnosticsSourceProvider],
/// [shareFnProvider]) so this is fully widget-testable without platform channels.
class ReportProblemButton extends ConsumerStatefulWidget {
  const ReportProblemButton({super.key, required this.error});

  /// The failure to attach to the report. It is NOT stringified raw — the report
  /// runs it through [describeError], a PII-safe type allowlist (a raw exception
  /// string could carry the request body). Passed as `Object?` so any layer's
  /// error can be reported; the safe projection happens at format time.
  final Object? error;

  @override
  ConsumerState<ReportProblemButton> createState() =>
      _ReportProblemButtonState();
}

class _ReportProblemButtonState extends ConsumerState<ReportProblemButton> {
  bool _busy = false;

  Future<void> _report() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final device = await ref.read(diagnosticsSourceProvider).collect();
      final report = formatErrorReport(
        error: widget.error,
        status: ref.read(networkStatusProvider),
        host: ref.read(configProvider).httpBaseUrl,
        device: device,
        nowUtc: DateTime.now().toUtc(),
      );
      await ref.read(shareFnProvider)(report);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open the report sheet.")),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: _busy ? null : _report,
      icon: const Icon(Icons.bug_report_outlined, size: 18),
      label: const Text('Report a problem'),
    );
  }
}
