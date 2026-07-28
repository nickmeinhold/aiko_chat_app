// Unit tests for the operator seat's application layer (#33/#35): the pending-
// reports queue controller — moderator-gated load, resolve/dismiss local removal,
// ban (no removal), and the Forbidden → /me-refresh reconciliation of a
// server-revoked moderator flag (A3: authZ denial is NOT a logout).
//
// Reuses the full-graph container from moderation_controller_test: faked seams +
// a real auth controller over an in-memory token store, then signs in.

import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/auth/token_provider.dart';
import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/data/cache/drift_cache.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart'
    show AccountSuspended, Forbidden;
import 'package:aiko_chat_app/features/moderation/application/moderation_controller.dart';
import 'package:aiko_chat_app/features/moderation/domain/moderation_models.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_chat_transport.dart';
import '../../support/fakes.dart';
import '../../support/ui_fakes.dart';

const _modUser = AppUser(
  userId: 'u1',
  username: 'nick',
  displayName: 'Nick',
  aikoUsername: 'nick',
  isModerator: true,
);

PendingReport _report(String id, {String sender = 'bad1'}) => PendingReport(
  reportId: id,
  messageId: 'm-$id',
  channelId: 'c1',
  reason: 'harassment',
  reporterDisplayName: 'Reporter',
  messageBody: 'something bad',
  messageSenderUserId: sender,
  createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  messageDeletedAt: null,
);

ProviderContainer _container(FakeRestApi rest) {
  late final ProviderContainer container;
  container = ProviderContainer(
    overrides: [
      restApiProvider.overrideWithValue(rest),
      transportProvider.overrideWithValue(FakeChatTransport()),
      passkeyAuthClientProvider.overrideWithValue(FakePasskeyAuthClient()),
      cachedUserStoreProvider.overrideWithValue(InMemoryCachedUserStore()),
      tokenProviderProvider.overrideWithValue(
        DefaultTokenProvider(
          store: InMemoryTokenStore(),
          remoteRefresh: (_) async => 'access2',
          onUnauthenticated: () => container.read(authEventsProvider).add(null),
        ),
      ),
      cacheProvider.overrideWith((ref) => DriftCache(NativeDatabase.memory())),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _loggedIn(FakeRestApi rest) async {
  final c = _container(rest);
  await c.read(authControllerProvider.future);
  await c.read(authControllerProvider.notifier).signInWithPasskey();
  return c;
}

void main() {
  group('PendingReport.fromJson', () {
    test('parses a full row and maps a known reason to its label', () {
      final r = PendingReport.fromJson(const {
        'report_id': 'r1',
        'message_id': 'm1',
        'channel_id': 'c1',
        'reason': 'harassment',
        'reporter_display_name': 'Alice',
        'message_body': 'bad',
        'message_sender_user_id': 'u9',
        'created_at': '2026-07-28T00:00:00Z',
        'message_deleted_at': null,
      });
      expect(r.reportId, 'r1');
      expect(r.reasonLabel, 'Harassment or bullying');
      expect(r.isAlreadyDeleted, isFalse);
    });

    test('lenient: missing fields never throw; unknown reason shows raw wire', () {
      final r = PendingReport.fromJson(const {
        'report_id': 'r2',
        'message_id': 'm2',
        'reason': 'some_future_reason',
      });
      expect(r.channelId, '');
      expect(r.reporterDisplayName, isNull);
      expect(r.reasonLabel, 'some_future_reason'); // unknown → raw wire, not dropped
      expect(r.createdAt.millisecondsSinceEpoch, 0); // epoch fallback
    });

    test('an already-soft-deleted message is flagged', () {
      final r = PendingReport.fromJson(const {
        'report_id': 'r3',
        'message_id': 'm3',
        'reason': 'spam',
        'message_deleted_at': '2026-07-28T01:00:00Z',
      });
      expect(r.isAlreadyDeleted, isTrue);
    });
  });

  group('pendingReportsProvider gating', () {
    test('a NON-moderator never calls the gated endpoint (empty queue)', () async {
      final rest = FakeRestApi(user: FakeRestApi.defaultUser); // isModerator=false
      rest.pendingReports = [_report('r1')];
      final c = await _loggedIn(rest);

      final reports = await c.read(pendingReportsProvider.future);
      expect(reports, isEmpty);
      // The whole point: no guaranteed-403 call for a plain user.
      expect(rest.listPendingReportsCalls, 0);
    });

    test('a moderator loads the pending queue', () async {
      final rest = FakeRestApi(user: _modUser);
      rest.pendingReports = [_report('r1'), _report('r2')];
      final c = await _loggedIn(rest);

      final reports = await c.read(pendingReportsProvider.future);
      expect(reports.map((r) => r.reportId), ['r1', 'r2']);
      expect(rest.listPendingReportsCalls, 1);
    });
  });

  group('operator actions', () {
    test('resolve takes down + removes that report from the queue', () async {
      final rest = FakeRestApi(user: _modUser);
      rest.pendingReports = [_report('r1'), _report('r2')];
      final c = await _loggedIn(rest);
      await c.read(pendingReportsProvider.future);

      await c.read(pendingReportsProvider.notifier).resolve('r1');

      expect(rest.resolvedReports, ['r1']);
      expect(
        c.read(pendingReportsProvider).value!.map((r) => r.reportId),
        ['r2'],
      );
    });

    test('dismiss removes that report from the queue', () async {
      final rest = FakeRestApi(user: _modUser);
      rest.pendingReports = [_report('r1'), _report('r2')];
      final c = await _loggedIn(rest);
      await c.read(pendingReportsProvider.future);

      await c.read(pendingReportsProvider.notifier).dismiss('r2');

      expect(rest.dismissedReports, ['r2']);
      expect(
        c.read(pendingReportsProvider).value!.map((r) => r.reportId),
        ['r1'],
      );
    });

    test('ban suspends the sender but LEAVES the report in the queue', () async {
      final rest = FakeRestApi(user: _modUser);
      rest.pendingReports = [_report('r1', sender: 'bad1')];
      final c = await _loggedIn(rest);
      await c.read(pendingReportsProvider.future);

      await c.read(pendingReportsProvider.notifier).ban('bad1');

      expect(rest.bannedUsers, ['bad1']);
      // Ban != resolve — the tile stays until the moderator acts on the report.
      expect(c.read(pendingReportsProvider).value, hasLength(1));
    });
  });

  group('Forbidden reconciliation (A3: authZ denial is not a logout)', () {
    test('a Forbidden action refreshes /me, flips the moderator flag off, '
        'and rethrows — never logs out', () async {
      final rest = FakeRestApi(user: _modUser);
      rest.pendingReports = [_report('r1')];
      final c = await _loggedIn(rest);
      await c.read(pendingReportsProvider.future);
      expect(c.read(isModeratorProvider), isTrue);

      // Server revokes moderator mid-session: the next operator action 403s, and
      // a fresh /me now returns a NON-moderator user.
      rest.operatorThrows = const Forbidden('/v1/reports/r1/resolve');
      rest.user = FakeRestApi.defaultUser; // me() now says: not a moderator

      await expectLater(
        c.read(pendingReportsProvider.notifier).resolve('r1'),
        throwsA(isA<Forbidden>()),
      );

      // Reconciled without a logout: still authenticated, flag now false.
      expect(c.read(authControllerProvider).value, isNotNull);
      expect(c.read(isModeratorProvider), isFalse);
    });

    test('a Forbidden on the INITIAL load (not just an action) reconciles /me '
        'and flips the flag off — the load path gates the UI too', () async {
      final rest = FakeRestApi(user: _modUser);
      final c = await _loggedIn(rest);
      expect(c.read(isModeratorProvider), isTrue);

      // Server revoked moderator BEFORE the screen opened: the first list 403s,
      // and a fresh /me now returns a non-moderator user.
      rest.operatorThrows = const Forbidden('/v1/reports');
      rest.user = FakeRestApi.defaultUser;

      // build() must NOT surface an error with the tile still lit — it returns
      // empty and schedules the /me reconcile in a microtask.
      final reports = await c.read(pendingReportsProvider.future);
      expect(reports, isEmpty);
      // Drain the scheduled refresh (microtask → me() → state flip → rebuild).
      await c.read(authControllerProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(isModeratorProvider), isFalse);
      expect(c.read(authControllerProvider).value, isNotNull); // never logged out
    });

    test('a BAN discovered during the Forbidden refresh routes to the suspended '
        'zone, NOT a plain logout (single suspended door)', () async {
      final rest = FakeRestApi(user: _modUser);
      rest.pendingReports = [_report('r1')];
      final c = await _loggedIn(rest);
      await c.read(pendingReportsProvider.future);

      // The action 403s; the reconciling /me reveals the account was BANNED.
      rest.operatorThrows = const Forbidden('/v1/reports/r1/resolve');
      rest.meThrows = const AccountSuspended();

      await expectLater(
        c.read(pendingReportsProvider.notifier).resolve('r1'),
        throwsA(isA<Forbidden>()),
      );

      // Settled through the suspended door (→ /suspended), not a bare logout that
      // would land on /login and 403-loop.
      expect(c.read(suspendedProvider), isTrue);
      expect(c.read(authControllerProvider).value, isNull);
    });
  });
}
