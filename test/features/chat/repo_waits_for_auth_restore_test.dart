/// "Could not load conversations" flashed on every cold start, and the comment
/// that said it couldn't is why nobody looked.
///
/// `chatRepositoryProvider` refuses to build a sessionless repo — correctly. But
/// `authControllerProvider` is `AsyncNotifierProvider<AuthController, AppUser?>`,
/// so while session restore is in flight the user is null and the repo is
/// legitimately in an ERROR state. Both conversation panes rendered any repo
/// error as *"Could not load conversations.\n<error>"*, so every launch — most
/// visibly right after an install — flashed a failure for a question that had
/// simply not been answered yet.
///
/// ## Why the fix is at the render decision and NOT in the repo provider
///
/// The first attempt made the repo `await` the auth future instead of reading
/// the flattened `.value`. That removed the flash and broke
/// `chat_screen_test.dart`'s *"logout → different user → no cross-session
/// messages"*: the synchronous throw is load-bearing for tearing the previous
/// session's repo down promptly, and deferring it leaked user A's message into
/// user B's session. A cosmetic flash traded for a cross-account leak — strictly
/// worse than the bug. The error is real; only its PRESENTATION was wrong.
///
/// So this file pins [authResolvedProvider] — the discriminator `.value` throws
/// away — rather than the repo's behaviour, which must not change.
///
/// Reported from a real handset by Nick, 2026-09-16, after an install.
library;

import 'package:aiko_chat_app/features/auth/application/auth_controller.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/chat/application/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _me = AppUser(
  userId: 'u1',
  username: 'nick',
  displayName: 'Nick',
  aikoUsername: 'nick',
);

/// Session restore that does NOT complete synchronously — the cold-start shape.
/// The real [AuthController.build] restores from secure storage, so the user is
/// null for a real interval on every launch; this reproduces that interval
/// deterministically rather than hoping a race shows up.
class _SlowRestoreAuthController extends AuthController {
  _SlowRestoreAuthController(this._user, this._delay);
  final AppUser? _user;
  final Duration _delay;
  @override
  Future<AppUser?> build() async {
    await Future<void>.delayed(_delay);
    return _user;
  }
}

class _FixedAuthController extends AuthController {
  _FixedAuthController(this._user);
  final AppUser? _user;
  @override
  Future<AppUser?> build() async => _user;
}

ProviderContainer _container(AuthController Function() auth) =>
    ProviderContainer(overrides: [authControllerProvider.overrideWith(auth)]);

void main() {
  test('restore in flight is NOT "resolved" — so a repo error stays a spinner, '
      'not "Could not load conversations"', () async {
    final container = _container(
      () => _SlowRestoreAuthController(_me, const Duration(milliseconds: 50)),
    );
    addTearDown(container.dispose);

    expect(
      container.read(authResolvedProvider),
      isFalse,
      reason: 'auth has not answered yet, so nothing may be called a failure',
    );

    await container.read(authControllerProvider.future);
    expect(container.read(authResolvedProvider), isTrue);
  });

  test(
    'logged out IS resolved — a genuine answer, and a real error may show',
    () async {
      // The must-fail arm. Without it the predicate could be "never true", which
      // would suppress every real error forever — a silent-failure bug traded for
      // a noisy one. `AsyncData(null)` is an ANSWER: the user is logged out.
      final container = _container(() => _FixedAuthController(null));
      addTearDown(container.dispose);

      await container.read(authControllerProvider.future);
      expect(
        container.read(authResolvedProvider),
        isTrue,
        reason: 'AsyncData(null) is a real answer, distinct from AsyncLoading',
      );
    },
  );

  test('signed in is resolved', () async {
    final container = _container(() => _FixedAuthController(_me));
    addTearDown(container.dispose);

    await container.read(authControllerProvider.future);
    expect(container.read(authResolvedProvider), isTrue);
  });

  /// THE FLASH SURVIVED THE FIX, and these tests are why it could.
  ///
  /// The originals above pin [authResolvedProvider] and nothing else — half of
  /// a two-term conjunction. The panes rendered
  /// `repoAsync.hasError && authResolved`, and the second term was never asked
  /// a question, so a defect living entirely in the FIRST term stayed green.
  /// Nick, from the handset, 2026-09-20: *"still comes up before the
  /// conversation loads"*.
  group('a REBUILDING provider still reports the error it is busy clearing', () {
    test(
      'VENDOR PIN: a rebuild after a failure is AsyncError(isLoading: true)',
      () async {
        // Measured against locked riverpod 3.4.2, not assumed. `hasError` is
        // `_error != null` (`lib/src/core/async_value.dart:125`), NOT
        // `this is AsyncError` — so the previous error rides along through the
        // rebuild for redraw convenience and keeps answering yes.
        //
        // Pinned as a test because `showsAsFailure` is built on it: if a future
        // riverpod drops the carried error, this goes red and says so, instead of
        // the predicate quietly becoming stricter than it needs to be.
        var failing = true;
        final probe = FutureProvider<int>((ref) async {
          if (failing) throw StateError('no session');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return 1;
        });
        final c = ProviderContainer();
        addTearDown(c.dispose);
        c.listen(probe, (_, __) {});
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(c.read(probe).hasError, isTrue);
        expect(c.read(probe).isLoading, isFalse, reason: 'settled failure');

        failing = false;
        c.invalidate(probe);
        final rebuilding = c.read(probe);
        expect(
          rebuilding.hasError,
          isTrue,
          reason: 'the OLD error is carried through the rebuild',
        );
        expect(
          rebuilding.isLoading,
          isTrue,
          reason: 'and it is busy succeeding',
        );
      },
    );

    test('a rebuilding repo is NOT a failure, even once auth has answered', () {
      // The exact cold-start instant the user sees: auth ANSWERED (so the old
      // guard opens), the repo is rebuilding with the sessionless error still
      // attached (so `hasError` is still true) — and the pane painted that as
      // "Could not load conversations" for the length of the repo build.
      final stale = AsyncError<int>(StateError('no session'), StackTrace.empty);
      // `copyWithPrevious` is Riverpod-
      // internal, and it is the only constructor for the state this test exists to
      // pin: LOADING while still carrying a previous error. That state is precisely
      // what `hasError` misreports (it is `_error != null`, not `this is AsyncError`),
      // and it is the instant the user saw the cold-start flash. Reaching for the
      // public API here would build a DIFFERENT value and the test would pass without
      // ever visiting the failing case.
      // ignore: invalid_use_of_internal_member
      final rebuilding = const AsyncLoading<int>().copyWithPrevious(stale);

      expect(rebuilding.hasError, isTrue, reason: 'precondition');
      expect(
        showsAsFailure(rebuilding, authResolved: true),
        isFalse,
        reason: 'still working is not yet failing',
      );
    });

    test('a SETTLED error with auth answered IS shown — the must-fail arm', () {
      // Without this the predicate could be "never true" and would suppress
      // every real failure forever: a silent bug traded for a noisy one, which
      // is strictly the worse trade and exactly what the first fix guarded
      // against one term over.
      final settled = AsyncError<int>(
        StateError('gateway down'),
        StackTrace.empty,
      );
      expect(showsAsFailure(settled, authResolved: true), isTrue);
    });

    test(
      'auth still restoring suppresses it regardless — the original bug',
      () {
        final settled = AsyncError<int>(
          StateError('no session'),
          StackTrace.empty,
        );
        expect(showsAsFailure(settled, authResolved: false), isFalse);
      },
    );

    test('success is never a failure', () {
      expect(
        showsAsFailure(const AsyncData<int>(1), authResolved: true),
        isFalse,
      );
      expect(
        showsAsFailure(const AsyncLoading<int>(), authResolved: true),
        isFalse,
      );
    });
  });
}
