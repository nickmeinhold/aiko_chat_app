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
    ProviderContainer(
      overrides: [authControllerProvider.overrideWith(auth)],
    );

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

  test('logged out IS resolved — a genuine answer, and a real error may show', () async {
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
  });

  test('signed in is resolved', () async {
    final container = _container(() => _FixedAuthController(_me));
    addTearDown(container.dispose);

    await container.read(authControllerProvider.future);
    expect(container.read(authResolvedProvider), isTrue);
  });
}
