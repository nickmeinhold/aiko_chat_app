// The problem-report bundle (error_report.dart) + the one-tap ReportProblemButton.
// The collect + share seams are provider-injected, so this drives the real
// button widget without touching device_info_plus/share_plus platform channels.

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/diagnostics/error_report.dart';
import 'package:aiko_chat_app/core/diagnostics/report_problem_button.dart';
import 'package:aiko_chat_app/core/network/network_status.dart';
import 'package:aiko_chat_app/features/auth/data/auth_exceptions.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDiagnostics implements DiagnosticsSource {
  _FakeDiagnostics(this.facts);
  final Map<String, String> facts;
  @override
  Future<Map<String, String>> collect() async => facts;
}

/// An error whose toString() leaks a credential — stands in for a raw
/// DioException whose requestOptions.data carries a provisioning_token.
class _LeakyError {
  @override
  String toString() =>
      'DioException: POST /v1/auth/social/claim data:{provisioning_token: SECRET-TOKEN-123}';
}

void main() {
  group(
    'describeError — PII-safe projection (never a raw exception string)',
    () {
      test('NetworkUnavailable drops its wrapped cause', () {
        // The cause is the DioException that could carry the request body.
        expect(
          describeError(const NetworkUnavailable('POST /claim {token: X}')),
          'NetworkUnavailable',
        );
      });

      test('a credential-leaking error collapses to its class name ONLY', () {
        final d = describeError(_LeakyError());
        expect(d, '_LeakyError');
        expect(d, isNot(contains('SECRET-TOKEN-123')));
        expect(d, isNot(contains('provisioning_token')));
      });

      test('safe domain exceptions keep their (safe) detail', () {
        expect(describeError(const Unauthorized(401)), 'Unauthorized(401)');
        expect(describeError(const HandleTaken()), 'HandleTaken');
        expect(
          describeError(const AuthCeremonyFailed('Passkey: no-credentials')),
          'AuthCeremonyFailed(Passkey: no-credentials)',
        );
      });

      test('null → "unknown"', () => expect(describeError(null), 'unknown'));
    },
  );

  group('formatErrorReport', () {
    test(
      'includes time, server, network, every device fact, and the error',
      () {
        final text = formatErrorReport(
          error: const NetworkUnavailable('dns'),
          status: NetworkStatus.offline,
          host: 'https://chat.example.com',
          device: {'App': 'Aiko Chat 0.0.1+6', 'Device': 'Google Pixel 7'},
          nowUtc: DateTime.utc(2026, 7, 11, 9, 51),
        );
        expect(text, contains('2026-07-11T09:51:00.000Z'));
        expect(text, contains('Server: https://chat.example.com'));
        expect(text, contains('Network (at report time): offline'));
        expect(text, contains('App: Aiko Chat 0.0.1+6'));
        expect(text, contains('Device: Google Pixel 7'));
        // Safe projection — the type, not the wrapped DioException detail.
        expect(text, contains('Error: NetworkUnavailable'));
        expect(text, isNot(contains('dns')));
      },
    );

    test('a credential-shaped error never reaches the shared text', () {
      final text = formatErrorReport(
        error: _LeakyError(),
        status: NetworkStatus.offline,
        host: 'h',
        device: const {},
        nowUtc: DateTime.utc(2026),
      );
      expect(text, isNot(contains('SECRET-TOKEN-123')));
      expect(text, contains('Error: _LeakyError'));
    });

    test('a null error degrades to "unknown", never throws', () {
      final text = formatErrorReport(
        error: null,
        status: NetworkStatus.online,
        host: 'h',
        device: const {},
        nowUtc: DateTime.utc(2026),
      );
      expect(text, contains('Error: unknown'));
    });
  });

  testWidgets('one tap bundles device + network + error into the share sheet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final shared = <String>[];
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        diagnosticsSourceProvider.overrideWithValue(
          _FakeDiagnostics({'Device': 'Google Pixel 7', 'OS': 'Android 14'}),
        ),
        shareFnProvider.overrideWithValue((t) async => shared.add(t)),
        networkStatusProvider.overrideWithValue(NetworkStatus.offline),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: ReportProblemButton(error: NetworkUnavailable()),
          ),
        ),
      ),
    );

    expect(find.text('Report a problem'), findsOneWidget);
    await tester.tap(find.text('Report a problem'));
    await tester.pumpAndSettle();

    expect(shared, hasLength(1));
    expect(shared.single, contains('Google Pixel 7'));
    expect(shared.single, contains('Network (at report time): offline'));
    expect(shared.single, contains('NetworkUnavailable'));
  });
}
