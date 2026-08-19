import 'dart:async';

import 'package:aiko_chat_app/features/notifications/domain/device_platform.dart';
import 'package:aiko_chat_app/features/auth/data/passkey_auth_client.dart';
import 'package:aiko_chat_app/features/auth/domain/auth_models.dart';
import 'package:aiko_chat_app/features/auth/domain/identity_models.dart';
import 'package:aiko_chat_app/features/call/domain/video_token.dart';
import 'package:aiko_chat_app/features/chat/data/chat_rest_api.dart';
import 'package:aiko_chat_app/features/chat/domain/channel.dart';
import 'package:aiko_chat_app/features/chat/domain/channel_member.dart';
import 'package:aiko_chat_app/features/chat/domain/gateway_capabilities.dart';
import 'package:aiko_chat_app/features/moderation/domain/moderation_models.dart';

/// A full-surface [ChatRestApi] fake for the widget/app-shell tests (the shipped
/// `FakeChatRestApi` only implements the B4 history slice). Each endpoint is
/// programmable; defaults are the happy path.
class FakeRestApi implements ChatRestApi {
  FakeRestApi({
    AppUser? user,
    List<Channel>? channels,
    this.meThrows,
  })  : user = user ?? defaultUser,
        channels = channels ?? const [defaultChannel];

  static const defaultUser = AppUser(
    userId: 'u1',
    username: 'nick',
    displayName: 'Nick',
    aikoUsername: 'nick',
  );
  static const defaultChannel =
      Channel(id: 'c1', name: 'general', kind: ChannelKind.standard);

  AppUser user;
  List<Channel> channels;

  /// The DM channels [listDms] returns (empty by default — most tests have none).
  List<Channel> dms = const [];

  /// If set, `me()` (cold-start restore) throws this.
  Object? meThrows;

  /// If set, `listChannels()` throws this (e.g. `NetworkUnavailable` to exercise
  /// the offline channel-cache fallback).
  Object? listChannelsThrows;

  /// When true, [listChannelsThrows] is cleared after the first throw — a
  /// TRANSIENT REST fault (fails once, healed by the time a retry lands).
  bool listChannelsThrowsOnce = false;

  /// If set, invoked INSIDE `me()` before it returns/throws — lets a test
  /// simulate a concurrent event (e.g. a terminal `unauthenticated` clearing
  /// tokens) racing the restore's `me()` call.
  void Function()? onMe;

  /// If set, `claimHandle` throws this (e.g. `HandleTaken`).
  Object? claimThrows;

  /// If set, `updateProfile` throws this (e.g. `HandleTaken`,
  /// `HandleChangeOnCooldown`) — exercises the settings edit-profile error UI.
  Object? updateProfileThrows;

  /// If set, `deleteAccount` throws this (e.g. `SoleAdminDeletionBlocked`).
  Object? deleteThrows;

  int meCalls = 0;
  int claimCalls = 0;
  int updateProfileCalls = 0;
  int deleteCalls = 0;
  int listChannelsCalls = 0;

  AuthSession _session() => AuthSession(
        user: user,
        tokens: const AuthTokens(accessToken: 'access', refreshToken: 'refresh'),
      );

  @override
  Future<String> refresh(String refreshToken) async => 'access2';

  @override
  Future<GatewayCapabilities?> getCapabilities() async => null;

  @override
  Future<AppUser> me() async {
    meCalls++;
    onMe?.call();
    if (meThrows != null) throw meThrows!;
    return user;
  }

  /// Programmable passkey outcomes. Default register: a new identity that must
  /// claim a handle (first-passkey-creates-account). Default authenticate: a
  /// known identity (log straight in). Override per-test.
  IdentityOutcome? passkeyRegisterOutcome;
  IdentityOutcome? passkeyAuthOutcome;

  int passkeyRegisterStartCalls = 0;
  int passkeyRegisterFinishCalls = 0;
  int passkeyAuthStartCalls = 0;
  int passkeyAuthFinishCalls = 0;
  String? lastPasskeyRegisterState;
  String? lastPasskeyRegisterCredential;
  String? lastPasskeyAuthState;
  String? lastPasskeyAuthCredential;

  @override
  Future<PasskeyChallenge> startPasskeyRegistration() async {
    passkeyRegisterStartCalls++;
    return (state: 'reg-state', optionsJson: '{"challenge":"reg-chal"}');
  }

  @override
  Future<IdentityOutcome> finishPasskeyRegistration(
      String state, String credentialJson) async {
    passkeyRegisterFinishCalls++;
    lastPasskeyRegisterState = state;
    lastPasskeyRegisterCredential = credentialJson;
    return passkeyRegisterOutcome ??
        const PendingHandle(
            provisioningToken: 'passkey-prov', suggestedName: null);
  }

  @override
  Future<PasskeyChallenge> startPasskeyAuthentication() async {
    passkeyAuthStartCalls++;
    return (state: 'auth-state', optionsJson: '{"challenge":"auth-chal"}');
  }

  @override
  Future<IdentityOutcome> finishPasskeyAuthentication(
      String state, String credentialJson) async {
    passkeyAuthFinishCalls++;
    lastPasskeyAuthState = state;
    lastPasskeyAuthCredential = credentialJson;
    if (finishAuthThrows != null) throw finishAuthThrows!;
    return passkeyAuthOutcome ?? Authenticated(_session());
  }

  /// If set, `finishPasskeyAuthentication` throws this (e.g. a ceremony that
  /// resolves to a banned account → `AccountSuspended`).
  Object? finishAuthThrows;

  /// If set, `addPasskey` throws this (e.g. `PasskeyAlreadyRegistered`).
  Object? addPasskeyThrows;
  int addPasskeyCalls = 0;
  String? lastAddPasskeyState;
  String? lastAddPasskeyCredential;

  @override
  Future<AppUser> addPasskey(String state, String credentialJson) async {
    addPasskeyCalls++;
    lastAddPasskeyState = state;
    lastAddPasskeyCredential = credentialJson;
    if (addPasskeyThrows != null) throw addPasskeyThrows!;
    return user;
  }

  @override
  Future<AuthSession> claimHandle({
    required String provisioningToken,
    required String handle,
    required String displayName,
  }) async {
    claimCalls++;
    if (claimThrows != null) throw claimThrows!;
    return _session();
  }

  @override
  Future<AppUser> updateProfile({String? handle, String? displayName}) async {
    updateProfileCalls++;
    if (updateProfileThrows != null) throw updateProfileThrows!;
    user = AppUser(
      userId: user.userId,
      username: handle ?? user.username,
      displayName: displayName ?? user.displayName,
      aikoUsername: handle ?? user.aikoUsername,
      isModerator: user.isModerator,
    );
    return user;
  }

  @override
  Future<void> deleteAccount() async {
    deleteCalls++;
    if (deleteThrows != null) throw deleteThrows!;
  }

  /// Device tokens this island believes are registered, in call order. A LIST
  /// rather than a set so a test can see a double-register, which is the shape
  /// of the bug the island's upsert exists to absorb.
  final List<({DevicePlatform platform, String token})> registeredDevices = [];
  final List<String> unregisteredDevices = [];
  Object? registerDeviceThrows;

  @override
  Future<void> registerDevice({
    required DevicePlatform platform,
    required String token,
  }) async {
    if (registerDeviceThrows != null) throw registerDeviceThrows!;
    registeredDevices.add((platform: platform, token: token));
  }

  @override
  Future<void> unregisterDevice(String token) async {
    unregisteredDevices.add(token);
  }

  /// Roster returned by [listMembers], keyed per channel id.
  final Map<String, List<ChannelMember>> membersByChannel = {};
  int listMembersCalls = 0;

  /// If set, `listMembers()` awaits this before returning — lets a test hold a
  /// roster unresolved and observe what a DM row renders in the meantime (a DM
  /// has no name of its own, so an unresolved roster is a visible placeholder).
  Completer<void>? listMembersGate;

  @override
  Future<List<ChannelMember>> listMembers(String channelId) async {
    listMembersCalls++;
    final gate = listMembersGate;
    if (gate != null) await gate.future;
    return membersByChannel[channelId] ?? const [];
  }

  /// If set, `listChannels()` awaits this before returning — the channels-side
  /// twin of [listDmsGate], so a test can control the SETTLE ORDER of the two
  /// sources the self-heal reads.
  Completer<void>? listChannelsGate;

  @override
  Future<List<Channel>> listChannels() async {
    listChannelsCalls++;
    final gate = listChannelsGate;
    if (gate != null) await gate.future;
    if (listChannelsThrows != null) {
      final e = listChannelsThrows!;
      if (listChannelsThrowsOnce) listChannelsThrows = null;
      throw e;
    }
    return channels;
  }

  /// If set, `listDms()` throws this (e.g. `NetworkUnavailable` to exercise the
  /// fail-soft branch in `dmsProvider`).
  Object? listDmsThrows;

  /// How many times `listDms()` was called — lets a test assert that a no-op
  /// seed did NOT invalidate `dmsProvider` (each invalidate costs a refetch AND
  /// a repository rebuild).
  int listDmsCalls = 0;

  /// If set, `listDms()` awaits this before returning — lets a test wedge a
  /// fetch mid-flight and drive the interleavings a settled fake cannot reach
  /// (a stale in-flight run completing AFTER a newer one invalidated it; the
  /// window between selecting a just-opened DM and the list confirming it).
  Completer<void>? listDmsGate;

  @override
  Future<List<Channel>> listDms() async {
    listDmsCalls++;
    // Snapshot at CALL time, like a real request: a fetch returns what the
    // server knew when it was issued, not when it happened to resolve. Lets a
    // test hold two fetches open and have them answer differently — the only way
    // to model a stale in-flight run racing a newer one.
    final snapshot = dms;
    final gate = listDmsGate;
    if (gate != null) await gate.future;
    if (listDmsThrows != null) throw listDmsThrows!;
    return snapshot;
  }

  /// If set, [requestVideoToken] throws this (e.g. `VideoNotEnabled`).
  Object? requestVideoTokenThrows;

  /// The token [requestVideoToken] returns when not throwing.
  VideoToken videoToken = const VideoToken(
      token: 'fake-jwt', url: 'wss://livekit.test', room: 'fake-room');

  int requestVideoTokenCalls = 0;

  @override
  Future<VideoToken> requestVideoToken(String channelId) async {
    requestVideoTokenCalls++;
    if (requestVideoTokenThrows != null) throw requestVideoTokenThrows!;
    return videoToken;
  }

  /// If set, [openDm] throws this (e.g. `DmTargetNotFound`, `NetworkUnavailable`).
  Object? openDmThrows;

  /// The DM channel [openDm] returns when not throwing. Defaults to a `kind: dm`
  /// channel so the call-affordance gate (kind == dm) lights up in tests.
  Channel openDmReturns = const Channel(
      id: 'dm:me:peer', name: '', kind: ChannelKind.dm);

  int openDmCalls = 0;

  /// The last target passed to [openDm] — lets a test assert the tapped sender's
  /// `userId` was threaded through (not, say, a display label).
  String? lastOpenDmTarget;

  @override
  Future<Channel> openDm(String targetUserId) async {
    openDmCalls++;
    lastOpenDmTarget = targetUserId;
    if (openDmThrows != null) throw openDmThrows!;
    return openDmReturns;
  }

  @override
  Future<HistoryPage> getHistory(String channelId,
          {String? before, String? after, int limit = 50}) async =>
      HistoryPage.ofMessages(channelId: channelId, messages: const []);

  // --- moderation (#7) — functional fakes so widget tests can drive block/report.

  /// Programmable: if set, the next block/unblock/report throws this.
  Object? moderationThrows;

  final List<BlockedUser> blocks = [];
  final List<(String messageId, ReportReason reason)> reportCalls = [];

  /// If set, `listBlocks` awaits this before returning — lets a test hold the
  /// initial load in flight to probe the block/build clobber race.
  Completer<void>? listBlocksGate;

  @override
  Future<void> blockUser(String userId) async {
    if (moderationThrows != null) throw moderationThrows!;
    if (blocks.any((b) => b.userId == userId)) return;
    blocks.insert(
        0,
        BlockedUser(
            userId: userId,
            displayName: 'User $userId',
            createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)));
  }

  @override
  Future<void> unblockUser(String userId) async {
    if (moderationThrows != null) throw moderationThrows!;
    blocks.removeWhere((b) => b.userId == userId);
  }

  @override
  Future<List<BlockedUser>> listBlocks() async {
    if (listBlocksGate != null) await listBlocksGate!.future;
    return List.unmodifiable(blocks);
  }

  @override
  Future<void> reportMessage(String messageId, ReportReason reason) async {
    if (moderationThrows != null) throw moderationThrows!;
    reportCalls.add((messageId, reason));
  }

  // --- operator / moderator actions (#33/#35) ---
  /// The queue `listPendingReports` returns. Settable per-test.
  List<PendingReport> pendingReports = const [];
  int listPendingReportsCalls = 0;
  final List<String> resolvedReports = [];
  final List<String> dismissedReports = [];
  final List<String> bannedUsers = [];

  /// If set, the operator actions below throw this (e.g. a [Forbidden] to
  /// exercise the stale-moderator-flag reconciliation).
  Object? operatorThrows;

  @override
  Future<List<PendingReport>> listPendingReports() async {
    listPendingReportsCalls++;
    if (operatorThrows != null) throw operatorThrows!;
    return List.unmodifiable(pendingReports);
  }

  @override
  Future<void> resolveReport(String reportId) async {
    if (operatorThrows != null) throw operatorThrows!;
    resolvedReports.add(reportId);
  }

  @override
  Future<void> dismissReport(String reportId) async {
    if (operatorThrows != null) throw operatorThrows!;
    dismissedReports.add(reportId);
  }

  @override
  Future<void> banUser(String userId) async {
    if (operatorThrows != null) throw operatorThrows!;
    bannedUsers.add(userId);
  }
}

/// A [PasskeyAuthClient] fake — returns canned attestation/assertion JSON (or
/// throws, e.g. [AuthCeremonyCancelled]) without touching a platform channel.
class FakePasskeyAuthClient implements PasskeyAuthClient {
  FakePasskeyAuthClient({
    this.attestation = 'fake-attestation',
    this.assertion = 'fake-assertion',
    this.registerThrows,
    this.authenticateThrows,
    this.gate,
  });

  /// If set, the matching call throws this instead of returning a credential.
  Object? registerThrows;
  Object? authenticateThrows;
  String attestation;
  String assertion;

  /// If set, [register]/[authenticate] park on this completer before resolving —
  /// lets a test hold a ceremony in-flight (the platform sheet "open") to probe
  /// the controller's single-flight guard against a concurrent second ingress.
  Completer<void>? gate;

  int registerCalls = 0;
  int authenticateCalls = 0;
  String? lastRegisterOptions;
  String? lastAuthenticateOptions;

  @override
  Future<String> register(String optionsJson) async {
    registerCalls++;
    lastRegisterOptions = optionsJson;
    if (gate != null) await gate!.future;
    if (registerThrows != null) throw registerThrows!;
    return attestation;
  }

  @override
  Future<String> authenticate(String optionsJson) async {
    authenticateCalls++;
    lastAuthenticateOptions = optionsJson;
    if (gate != null) await gate!.future;
    if (authenticateThrows != null) throw authenticateThrows!;
    return assertion;
  }
}
