import 'package:aiko_chat_app/app/providers.dart';
import 'package:aiko_chat_app/core/logging/log_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vault is the session's one owner only while there is one of it: a
/// second would keep its own lane, lease and flight over the same two slots.
void main() {
  test('the vault is never rebuilt, whatever its inputs do', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final vault = container.read(sessionVaultProvider);
    container.invalidate(rootLoggerProvider);
    container.invalidate(logSinkProvider);
    expect(identical(container.read(sessionVaultProvider), vault), isTrue);
  });
}
