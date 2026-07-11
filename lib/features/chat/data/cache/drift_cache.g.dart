// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'drift_cache.dart';

// ignore_for_file: type=lint
class $MessagesTable extends Messages
    with TableInfo<$MessagesTable, MessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _clientTempIdMeta = const VerificationMeta(
    'clientTempId',
  );
  @override
  late final GeneratedColumn<String> clientTempId = GeneratedColumn<String>(
    'client_temp_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverUlidMeta = const VerificationMeta(
    'serverUlid',
  );
  @override
  late final GeneratedColumn<String> serverUlid = GeneratedColumn<String>(
    'server_ulid',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _channelIdMeta = const VerificationMeta(
    'channelId',
  );
  @override
  late final GeneratedColumn<String> channelId = GeneratedColumn<String>(
    'channel_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderUserIdMeta = const VerificationMeta(
    'senderUserId',
  );
  @override
  late final GeneratedColumn<String> senderUserId = GeneratedColumn<String>(
    'sender_user_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _senderKindMeta = const VerificationMeta(
    'senderKind',
  );
  @override
  late final GeneratedColumn<String> senderKind = GeneratedColumn<String>(
    'sender_kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderLabelMeta = const VerificationMeta(
    'senderLabel',
  );
  @override
  late final GeneratedColumn<String> senderLabel = GeneratedColumn<String>(
    'sender_label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _replyToIdMeta = const VerificationMeta(
    'replyToId',
  );
  @override
  late final GeneratedColumn<String> replyToId = GeneratedColumn<String>(
    'reply_to_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localSeqMeta = const VerificationMeta(
    'localSeq',
  );
  @override
  late final GeneratedColumn<int> localSeq = GeneratedColumn<int>(
    'local_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _deliveryStateMeta = const VerificationMeta(
    'deliveryState',
  );
  @override
  late final GeneratedColumn<String> deliveryState = GeneratedColumn<String>(
    'delivery_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sigMeta = const VerificationMeta('sig');
  @override
  late final GeneratedColumn<String> sig = GeneratedColumn<String>(
    'sig',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _senderPubkeyMeta = const VerificationMeta(
    'senderPubkey',
  );
  @override
  late final GeneratedColumn<String> senderPubkey = GeneratedColumn<String>(
    'sender_pubkey',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _signedAtMsMeta = const VerificationMeta(
    'signedAtMs',
  );
  @override
  late final GeneratedColumn<int> signedAtMs = GeneratedColumn<int>(
    'signed_at_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _keyVersionMeta = const VerificationMeta(
    'keyVersion',
  );
  @override
  late final GeneratedColumn<int> keyVersion = GeneratedColumn<int>(
    'key_version',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _signedClientMsgIdMeta = const VerificationMeta(
    'signedClientMsgId',
  );
  @override
  late final GeneratedColumn<String> signedClientMsgId =
      GeneratedColumn<String>(
        'signed_client_msg_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _originCryptoValidMeta = const VerificationMeta(
    'originCryptoValid',
  );
  @override
  late final GeneratedColumn<int> originCryptoValid = GeneratedColumn<int>(
    'origin_crypto_valid',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    clientTempId,
    serverUlid,
    channelId,
    senderUserId,
    senderKind,
    senderLabel,
    kind,
    body,
    replyToId,
    createdAt,
    localSeq,
    deliveryState,
    sig,
    senderPubkey,
    signedAtMs,
    keyVersion,
    signedClientMsgId,
    originCryptoValid,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<MessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('client_temp_id')) {
      context.handle(
        _clientTempIdMeta,
        clientTempId.isAcceptableOrUnknown(
          data['client_temp_id']!,
          _clientTempIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_clientTempIdMeta);
    }
    if (data.containsKey('server_ulid')) {
      context.handle(
        _serverUlidMeta,
        serverUlid.isAcceptableOrUnknown(data['server_ulid']!, _serverUlidMeta),
      );
    }
    if (data.containsKey('channel_id')) {
      context.handle(
        _channelIdMeta,
        channelId.isAcceptableOrUnknown(data['channel_id']!, _channelIdMeta),
      );
    } else if (isInserting) {
      context.missing(_channelIdMeta);
    }
    if (data.containsKey('sender_user_id')) {
      context.handle(
        _senderUserIdMeta,
        senderUserId.isAcceptableOrUnknown(
          data['sender_user_id']!,
          _senderUserIdMeta,
        ),
      );
    }
    if (data.containsKey('sender_kind')) {
      context.handle(
        _senderKindMeta,
        senderKind.isAcceptableOrUnknown(data['sender_kind']!, _senderKindMeta),
      );
    } else if (isInserting) {
      context.missing(_senderKindMeta);
    }
    if (data.containsKey('sender_label')) {
      context.handle(
        _senderLabelMeta,
        senderLabel.isAcceptableOrUnknown(
          data['sender_label']!,
          _senderLabelMeta,
        ),
      );
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('reply_to_id')) {
      context.handle(
        _replyToIdMeta,
        replyToId.isAcceptableOrUnknown(data['reply_to_id']!, _replyToIdMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('local_seq')) {
      context.handle(
        _localSeqMeta,
        localSeq.isAcceptableOrUnknown(data['local_seq']!, _localSeqMeta),
      );
    }
    if (data.containsKey('delivery_state')) {
      context.handle(
        _deliveryStateMeta,
        deliveryState.isAcceptableOrUnknown(
          data['delivery_state']!,
          _deliveryStateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_deliveryStateMeta);
    }
    if (data.containsKey('sig')) {
      context.handle(
        _sigMeta,
        sig.isAcceptableOrUnknown(data['sig']!, _sigMeta),
      );
    }
    if (data.containsKey('sender_pubkey')) {
      context.handle(
        _senderPubkeyMeta,
        senderPubkey.isAcceptableOrUnknown(
          data['sender_pubkey']!,
          _senderPubkeyMeta,
        ),
      );
    }
    if (data.containsKey('signed_at_ms')) {
      context.handle(
        _signedAtMsMeta,
        signedAtMs.isAcceptableOrUnknown(
          data['signed_at_ms']!,
          _signedAtMsMeta,
        ),
      );
    }
    if (data.containsKey('key_version')) {
      context.handle(
        _keyVersionMeta,
        keyVersion.isAcceptableOrUnknown(data['key_version']!, _keyVersionMeta),
      );
    }
    if (data.containsKey('signed_client_msg_id')) {
      context.handle(
        _signedClientMsgIdMeta,
        signedClientMsgId.isAcceptableOrUnknown(
          data['signed_client_msg_id']!,
          _signedClientMsgIdMeta,
        ),
      );
    }
    if (data.containsKey('origin_crypto_valid')) {
      context.handle(
        _originCryptoValidMeta,
        originCryptoValid.isAcceptableOrUnknown(
          data['origin_crypto_valid']!,
          _originCryptoValidMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {clientTempId};
  @override
  MessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageRow(
      clientTempId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_temp_id'],
      )!,
      serverUlid: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_ulid'],
      ),
      channelId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}channel_id'],
      )!,
      senderUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_user_id'],
      ),
      senderKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_kind'],
      )!,
      senderLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_label'],
      ),
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      replyToId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reply_to_id'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      localSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}local_seq'],
      )!,
      deliveryState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}delivery_state'],
      )!,
      sig: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sig'],
      ),
      senderPubkey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_pubkey'],
      ),
      signedAtMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}signed_at_ms'],
      ),
      keyVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}key_version'],
      ),
      signedClientMsgId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}signed_client_msg_id'],
      ),
      originCryptoValid: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}origin_crypto_valid'],
      ),
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }
}

class MessageRow extends DataClass implements Insertable<MessageRow> {
  /// Durable PK — client uuid for optimistic rows, the server ULID for inbound.
  final String clientTempId;

  /// Dedup authority. NULL until acked; SQLite allows many NULLs in a UNIQUE
  /// index, which is exactly what lets un-acked optimistic rows coexist
  /// (Invariant U is "every NON-NULL serverUlid is unique").
  final String? serverUlid;
  final String channelId;
  final String? senderUserId;
  final String senderKind;
  final String? senderLabel;
  final String kind;
  final String body;
  final String? replyToId;

  /// UTC unix millis. Server time once acked; clamped client time while pending.
  final int createdAt;

  /// DB-derived monotonic compose counter (W1: MAX+1 in-txn). Send-order
  /// tiebreak so rapid sends under a skewed clock keep compose order. 0 inbound.
  final int localSeq;
  final String deliveryState;

  /// Sovereign message signature (sovereign-message-signing, schema v3). All
  /// nullable: pre-feature rows and inbound rows have none. LOCAL verifiable
  /// history only — NOT emitted on the wire yet (gated on gateway carriage). See
  /// `docs/crucible/sovereign-message-signing/SIGNING-SPEC.md`.
  final String? sig;
  final String? senderPubkey;

  /// The SIGNED compose time — persisted separately from [createdAt] because ack
  /// reconciliation overwrites createdAt with server time, which would break
  /// verification of the signed bytes.
  final int? signedAtMs;
  final int? keyVersion;

  /// The SIGNED `client_msg_id` (wire-half, schema v4). For an OUTBOUND row the
  /// signed id IS [clientTempId], so this stays NULL and readers fall back to it.
  /// For an INBOUND row [clientTempId] is the server ULID — NOT what was signed —
  /// so the sender's signed `origin.client_msg_id` is stored here, keeping the
  /// persisted signature independently re-verifiable (same rationale as storing
  /// [signedAtMs] separately from [createdAt]).
  final String? signedClientMsgId;

  /// The local verify verdict for an INBOUND origin, computed once at ingest
  /// (wire-half, schema v4). NULL = no origin / our own outbound sig (self-
  /// verified at sign-time, never re-checked); 1 = carried-and-verified; 0 =
  /// carried-but-invalid. DATA, not UI (no "verified sender" badge until PR B).
  final int? originCryptoValid;
  const MessageRow({
    required this.clientTempId,
    this.serverUlid,
    required this.channelId,
    this.senderUserId,
    required this.senderKind,
    this.senderLabel,
    required this.kind,
    required this.body,
    this.replyToId,
    required this.createdAt,
    required this.localSeq,
    required this.deliveryState,
    this.sig,
    this.senderPubkey,
    this.signedAtMs,
    this.keyVersion,
    this.signedClientMsgId,
    this.originCryptoValid,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['client_temp_id'] = Variable<String>(clientTempId);
    if (!nullToAbsent || serverUlid != null) {
      map['server_ulid'] = Variable<String>(serverUlid);
    }
    map['channel_id'] = Variable<String>(channelId);
    if (!nullToAbsent || senderUserId != null) {
      map['sender_user_id'] = Variable<String>(senderUserId);
    }
    map['sender_kind'] = Variable<String>(senderKind);
    if (!nullToAbsent || senderLabel != null) {
      map['sender_label'] = Variable<String>(senderLabel);
    }
    map['kind'] = Variable<String>(kind);
    map['body'] = Variable<String>(body);
    if (!nullToAbsent || replyToId != null) {
      map['reply_to_id'] = Variable<String>(replyToId);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['local_seq'] = Variable<int>(localSeq);
    map['delivery_state'] = Variable<String>(deliveryState);
    if (!nullToAbsent || sig != null) {
      map['sig'] = Variable<String>(sig);
    }
    if (!nullToAbsent || senderPubkey != null) {
      map['sender_pubkey'] = Variable<String>(senderPubkey);
    }
    if (!nullToAbsent || signedAtMs != null) {
      map['signed_at_ms'] = Variable<int>(signedAtMs);
    }
    if (!nullToAbsent || keyVersion != null) {
      map['key_version'] = Variable<int>(keyVersion);
    }
    if (!nullToAbsent || signedClientMsgId != null) {
      map['signed_client_msg_id'] = Variable<String>(signedClientMsgId);
    }
    if (!nullToAbsent || originCryptoValid != null) {
      map['origin_crypto_valid'] = Variable<int>(originCryptoValid);
    }
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      clientTempId: Value(clientTempId),
      serverUlid: serverUlid == null && nullToAbsent
          ? const Value.absent()
          : Value(serverUlid),
      channelId: Value(channelId),
      senderUserId: senderUserId == null && nullToAbsent
          ? const Value.absent()
          : Value(senderUserId),
      senderKind: Value(senderKind),
      senderLabel: senderLabel == null && nullToAbsent
          ? const Value.absent()
          : Value(senderLabel),
      kind: Value(kind),
      body: Value(body),
      replyToId: replyToId == null && nullToAbsent
          ? const Value.absent()
          : Value(replyToId),
      createdAt: Value(createdAt),
      localSeq: Value(localSeq),
      deliveryState: Value(deliveryState),
      sig: sig == null && nullToAbsent ? const Value.absent() : Value(sig),
      senderPubkey: senderPubkey == null && nullToAbsent
          ? const Value.absent()
          : Value(senderPubkey),
      signedAtMs: signedAtMs == null && nullToAbsent
          ? const Value.absent()
          : Value(signedAtMs),
      keyVersion: keyVersion == null && nullToAbsent
          ? const Value.absent()
          : Value(keyVersion),
      signedClientMsgId: signedClientMsgId == null && nullToAbsent
          ? const Value.absent()
          : Value(signedClientMsgId),
      originCryptoValid: originCryptoValid == null && nullToAbsent
          ? const Value.absent()
          : Value(originCryptoValid),
    );
  }

  factory MessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageRow(
      clientTempId: serializer.fromJson<String>(json['clientTempId']),
      serverUlid: serializer.fromJson<String?>(json['serverUlid']),
      channelId: serializer.fromJson<String>(json['channelId']),
      senderUserId: serializer.fromJson<String?>(json['senderUserId']),
      senderKind: serializer.fromJson<String>(json['senderKind']),
      senderLabel: serializer.fromJson<String?>(json['senderLabel']),
      kind: serializer.fromJson<String>(json['kind']),
      body: serializer.fromJson<String>(json['body']),
      replyToId: serializer.fromJson<String?>(json['replyToId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      localSeq: serializer.fromJson<int>(json['localSeq']),
      deliveryState: serializer.fromJson<String>(json['deliveryState']),
      sig: serializer.fromJson<String?>(json['sig']),
      senderPubkey: serializer.fromJson<String?>(json['senderPubkey']),
      signedAtMs: serializer.fromJson<int?>(json['signedAtMs']),
      keyVersion: serializer.fromJson<int?>(json['keyVersion']),
      signedClientMsgId: serializer.fromJson<String?>(
        json['signedClientMsgId'],
      ),
      originCryptoValid: serializer.fromJson<int?>(json['originCryptoValid']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'clientTempId': serializer.toJson<String>(clientTempId),
      'serverUlid': serializer.toJson<String?>(serverUlid),
      'channelId': serializer.toJson<String>(channelId),
      'senderUserId': serializer.toJson<String?>(senderUserId),
      'senderKind': serializer.toJson<String>(senderKind),
      'senderLabel': serializer.toJson<String?>(senderLabel),
      'kind': serializer.toJson<String>(kind),
      'body': serializer.toJson<String>(body),
      'replyToId': serializer.toJson<String?>(replyToId),
      'createdAt': serializer.toJson<int>(createdAt),
      'localSeq': serializer.toJson<int>(localSeq),
      'deliveryState': serializer.toJson<String>(deliveryState),
      'sig': serializer.toJson<String?>(sig),
      'senderPubkey': serializer.toJson<String?>(senderPubkey),
      'signedAtMs': serializer.toJson<int?>(signedAtMs),
      'keyVersion': serializer.toJson<int?>(keyVersion),
      'signedClientMsgId': serializer.toJson<String?>(signedClientMsgId),
      'originCryptoValid': serializer.toJson<int?>(originCryptoValid),
    };
  }

  MessageRow copyWith({
    String? clientTempId,
    Value<String?> serverUlid = const Value.absent(),
    String? channelId,
    Value<String?> senderUserId = const Value.absent(),
    String? senderKind,
    Value<String?> senderLabel = const Value.absent(),
    String? kind,
    String? body,
    Value<String?> replyToId = const Value.absent(),
    int? createdAt,
    int? localSeq,
    String? deliveryState,
    Value<String?> sig = const Value.absent(),
    Value<String?> senderPubkey = const Value.absent(),
    Value<int?> signedAtMs = const Value.absent(),
    Value<int?> keyVersion = const Value.absent(),
    Value<String?> signedClientMsgId = const Value.absent(),
    Value<int?> originCryptoValid = const Value.absent(),
  }) => MessageRow(
    clientTempId: clientTempId ?? this.clientTempId,
    serverUlid: serverUlid.present ? serverUlid.value : this.serverUlid,
    channelId: channelId ?? this.channelId,
    senderUserId: senderUserId.present ? senderUserId.value : this.senderUserId,
    senderKind: senderKind ?? this.senderKind,
    senderLabel: senderLabel.present ? senderLabel.value : this.senderLabel,
    kind: kind ?? this.kind,
    body: body ?? this.body,
    replyToId: replyToId.present ? replyToId.value : this.replyToId,
    createdAt: createdAt ?? this.createdAt,
    localSeq: localSeq ?? this.localSeq,
    deliveryState: deliveryState ?? this.deliveryState,
    sig: sig.present ? sig.value : this.sig,
    senderPubkey: senderPubkey.present ? senderPubkey.value : this.senderPubkey,
    signedAtMs: signedAtMs.present ? signedAtMs.value : this.signedAtMs,
    keyVersion: keyVersion.present ? keyVersion.value : this.keyVersion,
    signedClientMsgId: signedClientMsgId.present
        ? signedClientMsgId.value
        : this.signedClientMsgId,
    originCryptoValid: originCryptoValid.present
        ? originCryptoValid.value
        : this.originCryptoValid,
  );
  MessageRow copyWithCompanion(MessagesCompanion data) {
    return MessageRow(
      clientTempId: data.clientTempId.present
          ? data.clientTempId.value
          : this.clientTempId,
      serverUlid: data.serverUlid.present
          ? data.serverUlid.value
          : this.serverUlid,
      channelId: data.channelId.present ? data.channelId.value : this.channelId,
      senderUserId: data.senderUserId.present
          ? data.senderUserId.value
          : this.senderUserId,
      senderKind: data.senderKind.present
          ? data.senderKind.value
          : this.senderKind,
      senderLabel: data.senderLabel.present
          ? data.senderLabel.value
          : this.senderLabel,
      kind: data.kind.present ? data.kind.value : this.kind,
      body: data.body.present ? data.body.value : this.body,
      replyToId: data.replyToId.present ? data.replyToId.value : this.replyToId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      localSeq: data.localSeq.present ? data.localSeq.value : this.localSeq,
      deliveryState: data.deliveryState.present
          ? data.deliveryState.value
          : this.deliveryState,
      sig: data.sig.present ? data.sig.value : this.sig,
      senderPubkey: data.senderPubkey.present
          ? data.senderPubkey.value
          : this.senderPubkey,
      signedAtMs: data.signedAtMs.present
          ? data.signedAtMs.value
          : this.signedAtMs,
      keyVersion: data.keyVersion.present
          ? data.keyVersion.value
          : this.keyVersion,
      signedClientMsgId: data.signedClientMsgId.present
          ? data.signedClientMsgId.value
          : this.signedClientMsgId,
      originCryptoValid: data.originCryptoValid.present
          ? data.originCryptoValid.value
          : this.originCryptoValid,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageRow(')
          ..write('clientTempId: $clientTempId, ')
          ..write('serverUlid: $serverUlid, ')
          ..write('channelId: $channelId, ')
          ..write('senderUserId: $senderUserId, ')
          ..write('senderKind: $senderKind, ')
          ..write('senderLabel: $senderLabel, ')
          ..write('kind: $kind, ')
          ..write('body: $body, ')
          ..write('replyToId: $replyToId, ')
          ..write('createdAt: $createdAt, ')
          ..write('localSeq: $localSeq, ')
          ..write('deliveryState: $deliveryState, ')
          ..write('sig: $sig, ')
          ..write('senderPubkey: $senderPubkey, ')
          ..write('signedAtMs: $signedAtMs, ')
          ..write('keyVersion: $keyVersion, ')
          ..write('signedClientMsgId: $signedClientMsgId, ')
          ..write('originCryptoValid: $originCryptoValid')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    clientTempId,
    serverUlid,
    channelId,
    senderUserId,
    senderKind,
    senderLabel,
    kind,
    body,
    replyToId,
    createdAt,
    localSeq,
    deliveryState,
    sig,
    senderPubkey,
    signedAtMs,
    keyVersion,
    signedClientMsgId,
    originCryptoValid,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageRow &&
          other.clientTempId == this.clientTempId &&
          other.serverUlid == this.serverUlid &&
          other.channelId == this.channelId &&
          other.senderUserId == this.senderUserId &&
          other.senderKind == this.senderKind &&
          other.senderLabel == this.senderLabel &&
          other.kind == this.kind &&
          other.body == this.body &&
          other.replyToId == this.replyToId &&
          other.createdAt == this.createdAt &&
          other.localSeq == this.localSeq &&
          other.deliveryState == this.deliveryState &&
          other.sig == this.sig &&
          other.senderPubkey == this.senderPubkey &&
          other.signedAtMs == this.signedAtMs &&
          other.keyVersion == this.keyVersion &&
          other.signedClientMsgId == this.signedClientMsgId &&
          other.originCryptoValid == this.originCryptoValid);
}

class MessagesCompanion extends UpdateCompanion<MessageRow> {
  final Value<String> clientTempId;
  final Value<String?> serverUlid;
  final Value<String> channelId;
  final Value<String?> senderUserId;
  final Value<String> senderKind;
  final Value<String?> senderLabel;
  final Value<String> kind;
  final Value<String> body;
  final Value<String?> replyToId;
  final Value<int> createdAt;
  final Value<int> localSeq;
  final Value<String> deliveryState;
  final Value<String?> sig;
  final Value<String?> senderPubkey;
  final Value<int?> signedAtMs;
  final Value<int?> keyVersion;
  final Value<String?> signedClientMsgId;
  final Value<int?> originCryptoValid;
  final Value<int> rowid;
  const MessagesCompanion({
    this.clientTempId = const Value.absent(),
    this.serverUlid = const Value.absent(),
    this.channelId = const Value.absent(),
    this.senderUserId = const Value.absent(),
    this.senderKind = const Value.absent(),
    this.senderLabel = const Value.absent(),
    this.kind = const Value.absent(),
    this.body = const Value.absent(),
    this.replyToId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.localSeq = const Value.absent(),
    this.deliveryState = const Value.absent(),
    this.sig = const Value.absent(),
    this.senderPubkey = const Value.absent(),
    this.signedAtMs = const Value.absent(),
    this.keyVersion = const Value.absent(),
    this.signedClientMsgId = const Value.absent(),
    this.originCryptoValid = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagesCompanion.insert({
    required String clientTempId,
    this.serverUlid = const Value.absent(),
    required String channelId,
    this.senderUserId = const Value.absent(),
    required String senderKind,
    this.senderLabel = const Value.absent(),
    required String kind,
    required String body,
    this.replyToId = const Value.absent(),
    required int createdAt,
    this.localSeq = const Value.absent(),
    required String deliveryState,
    this.sig = const Value.absent(),
    this.senderPubkey = const Value.absent(),
    this.signedAtMs = const Value.absent(),
    this.keyVersion = const Value.absent(),
    this.signedClientMsgId = const Value.absent(),
    this.originCryptoValid = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : clientTempId = Value(clientTempId),
       channelId = Value(channelId),
       senderKind = Value(senderKind),
       kind = Value(kind),
       body = Value(body),
       createdAt = Value(createdAt),
       deliveryState = Value(deliveryState);
  static Insertable<MessageRow> custom({
    Expression<String>? clientTempId,
    Expression<String>? serverUlid,
    Expression<String>? channelId,
    Expression<String>? senderUserId,
    Expression<String>? senderKind,
    Expression<String>? senderLabel,
    Expression<String>? kind,
    Expression<String>? body,
    Expression<String>? replyToId,
    Expression<int>? createdAt,
    Expression<int>? localSeq,
    Expression<String>? deliveryState,
    Expression<String>? sig,
    Expression<String>? senderPubkey,
    Expression<int>? signedAtMs,
    Expression<int>? keyVersion,
    Expression<String>? signedClientMsgId,
    Expression<int>? originCryptoValid,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (clientTempId != null) 'client_temp_id': clientTempId,
      if (serverUlid != null) 'server_ulid': serverUlid,
      if (channelId != null) 'channel_id': channelId,
      if (senderUserId != null) 'sender_user_id': senderUserId,
      if (senderKind != null) 'sender_kind': senderKind,
      if (senderLabel != null) 'sender_label': senderLabel,
      if (kind != null) 'kind': kind,
      if (body != null) 'body': body,
      if (replyToId != null) 'reply_to_id': replyToId,
      if (createdAt != null) 'created_at': createdAt,
      if (localSeq != null) 'local_seq': localSeq,
      if (deliveryState != null) 'delivery_state': deliveryState,
      if (sig != null) 'sig': sig,
      if (senderPubkey != null) 'sender_pubkey': senderPubkey,
      if (signedAtMs != null) 'signed_at_ms': signedAtMs,
      if (keyVersion != null) 'key_version': keyVersion,
      if (signedClientMsgId != null) 'signed_client_msg_id': signedClientMsgId,
      if (originCryptoValid != null) 'origin_crypto_valid': originCryptoValid,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagesCompanion copyWith({
    Value<String>? clientTempId,
    Value<String?>? serverUlid,
    Value<String>? channelId,
    Value<String?>? senderUserId,
    Value<String>? senderKind,
    Value<String?>? senderLabel,
    Value<String>? kind,
    Value<String>? body,
    Value<String?>? replyToId,
    Value<int>? createdAt,
    Value<int>? localSeq,
    Value<String>? deliveryState,
    Value<String?>? sig,
    Value<String?>? senderPubkey,
    Value<int?>? signedAtMs,
    Value<int?>? keyVersion,
    Value<String?>? signedClientMsgId,
    Value<int?>? originCryptoValid,
    Value<int>? rowid,
  }) {
    return MessagesCompanion(
      clientTempId: clientTempId ?? this.clientTempId,
      serverUlid: serverUlid ?? this.serverUlid,
      channelId: channelId ?? this.channelId,
      senderUserId: senderUserId ?? this.senderUserId,
      senderKind: senderKind ?? this.senderKind,
      senderLabel: senderLabel ?? this.senderLabel,
      kind: kind ?? this.kind,
      body: body ?? this.body,
      replyToId: replyToId ?? this.replyToId,
      createdAt: createdAt ?? this.createdAt,
      localSeq: localSeq ?? this.localSeq,
      deliveryState: deliveryState ?? this.deliveryState,
      sig: sig ?? this.sig,
      senderPubkey: senderPubkey ?? this.senderPubkey,
      signedAtMs: signedAtMs ?? this.signedAtMs,
      keyVersion: keyVersion ?? this.keyVersion,
      signedClientMsgId: signedClientMsgId ?? this.signedClientMsgId,
      originCryptoValid: originCryptoValid ?? this.originCryptoValid,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (clientTempId.present) {
      map['client_temp_id'] = Variable<String>(clientTempId.value);
    }
    if (serverUlid.present) {
      map['server_ulid'] = Variable<String>(serverUlid.value);
    }
    if (channelId.present) {
      map['channel_id'] = Variable<String>(channelId.value);
    }
    if (senderUserId.present) {
      map['sender_user_id'] = Variable<String>(senderUserId.value);
    }
    if (senderKind.present) {
      map['sender_kind'] = Variable<String>(senderKind.value);
    }
    if (senderLabel.present) {
      map['sender_label'] = Variable<String>(senderLabel.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (replyToId.present) {
      map['reply_to_id'] = Variable<String>(replyToId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (localSeq.present) {
      map['local_seq'] = Variable<int>(localSeq.value);
    }
    if (deliveryState.present) {
      map['delivery_state'] = Variable<String>(deliveryState.value);
    }
    if (sig.present) {
      map['sig'] = Variable<String>(sig.value);
    }
    if (senderPubkey.present) {
      map['sender_pubkey'] = Variable<String>(senderPubkey.value);
    }
    if (signedAtMs.present) {
      map['signed_at_ms'] = Variable<int>(signedAtMs.value);
    }
    if (keyVersion.present) {
      map['key_version'] = Variable<int>(keyVersion.value);
    }
    if (signedClientMsgId.present) {
      map['signed_client_msg_id'] = Variable<String>(signedClientMsgId.value);
    }
    if (originCryptoValid.present) {
      map['origin_crypto_valid'] = Variable<int>(originCryptoValid.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('clientTempId: $clientTempId, ')
          ..write('serverUlid: $serverUlid, ')
          ..write('channelId: $channelId, ')
          ..write('senderUserId: $senderUserId, ')
          ..write('senderKind: $senderKind, ')
          ..write('senderLabel: $senderLabel, ')
          ..write('kind: $kind, ')
          ..write('body: $body, ')
          ..write('replyToId: $replyToId, ')
          ..write('createdAt: $createdAt, ')
          ..write('localSeq: $localSeq, ')
          ..write('deliveryState: $deliveryState, ')
          ..write('sig: $sig, ')
          ..write('senderPubkey: $senderPubkey, ')
          ..write('signedAtMs: $signedAtMs, ')
          ..write('keyVersion: $keyVersion, ')
          ..write('signedClientMsgId: $signedClientMsgId, ')
          ..write('originCryptoValid: $originCryptoValid, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ChannelsTable extends Channels
    with TableInfo<$ChannelsTable, ChannelRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChannelsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _aikoChannelMeta = const VerificationMeta(
    'aikoChannel',
  );
  @override
  late final GeneratedColumn<String> aikoChannel = GeneratedColumn<String>(
    'aiko_channel',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, kind, aikoChannel];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'channels';
  @override
  VerificationContext validateIntegrity(
    Insertable<ChannelRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('aiko_channel')) {
      context.handle(
        _aikoChannelMeta,
        aikoChannel.isAcceptableOrUnknown(
          data['aiko_channel']!,
          _aikoChannelMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ChannelRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChannelRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      aikoChannel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}aiko_channel'],
      ),
    );
  }

  @override
  $ChannelsTable createAlias(String alias) {
    return $ChannelsTable(attachedDatabase, alias);
  }
}

class ChannelRow extends DataClass implements Insertable<ChannelRow> {
  final String id;
  final String name;
  final String kind;
  final String? aikoChannel;
  const ChannelRow({
    required this.id,
    required this.name,
    required this.kind,
    this.aikoChannel,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || aikoChannel != null) {
      map['aiko_channel'] = Variable<String>(aikoChannel);
    }
    return map;
  }

  ChannelsCompanion toCompanion(bool nullToAbsent) {
    return ChannelsCompanion(
      id: Value(id),
      name: Value(name),
      kind: Value(kind),
      aikoChannel: aikoChannel == null && nullToAbsent
          ? const Value.absent()
          : Value(aikoChannel),
    );
  }

  factory ChannelRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChannelRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      kind: serializer.fromJson<String>(json['kind']),
      aikoChannel: serializer.fromJson<String?>(json['aikoChannel']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'kind': serializer.toJson<String>(kind),
      'aikoChannel': serializer.toJson<String?>(aikoChannel),
    };
  }

  ChannelRow copyWith({
    String? id,
    String? name,
    String? kind,
    Value<String?> aikoChannel = const Value.absent(),
  }) => ChannelRow(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    aikoChannel: aikoChannel.present ? aikoChannel.value : this.aikoChannel,
  );
  ChannelRow copyWithCompanion(ChannelsCompanion data) {
    return ChannelRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      kind: data.kind.present ? data.kind.value : this.kind,
      aikoChannel: data.aikoChannel.present
          ? data.aikoChannel.value
          : this.aikoChannel,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChannelRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('aikoChannel: $aikoChannel')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, kind, aikoChannel);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChannelRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.kind == this.kind &&
          other.aikoChannel == this.aikoChannel);
}

class ChannelsCompanion extends UpdateCompanion<ChannelRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> kind;
  final Value<String?> aikoChannel;
  final Value<int> rowid;
  const ChannelsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.kind = const Value.absent(),
    this.aikoChannel = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ChannelsCompanion.insert({
    required String id,
    required String name,
    required String kind,
    this.aikoChannel = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       kind = Value(kind);
  static Insertable<ChannelRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? kind,
    Expression<String>? aikoChannel,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (kind != null) 'kind': kind,
      if (aikoChannel != null) 'aiko_channel': aikoChannel,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ChannelsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? kind,
    Value<String?>? aikoChannel,
    Value<int>? rowid,
  }) {
    return ChannelsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      aikoChannel: aikoChannel ?? this.aikoChannel,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (aikoChannel.present) {
      map['aiko_channel'] = Variable<String>(aikoChannel.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChannelsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('aikoChannel: $aikoChannel, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncMetaTable extends SyncMeta
    with TableInfo<$SyncMetaTable, SyncMetaData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _channelIdMeta = const VerificationMeta(
    'channelId',
  );
  @override
  late final GeneratedColumn<String> channelId = GeneratedColumn<String>(
    'channel_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _historyContiguousThroughMeta =
      const VerificationMeta('historyContiguousThrough');
  @override
  late final GeneratedColumn<String> historyContiguousThrough =
      GeneratedColumn<String>(
        'history_contiguous_through',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [channelId, historyContiguousThrough];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncMetaData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('channel_id')) {
      context.handle(
        _channelIdMeta,
        channelId.isAcceptableOrUnknown(data['channel_id']!, _channelIdMeta),
      );
    } else if (isInserting) {
      context.missing(_channelIdMeta);
    }
    if (data.containsKey('history_contiguous_through')) {
      context.handle(
        _historyContiguousThroughMeta,
        historyContiguousThrough.isAcceptableOrUnknown(
          data['history_contiguous_through']!,
          _historyContiguousThroughMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {channelId};
  @override
  SyncMetaData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncMetaData(
      channelId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}channel_id'],
      )!,
      historyContiguousThrough: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}history_contiguous_through'],
      ),
    );
  }

  @override
  $SyncMetaTable createAlias(String alias) {
    return $SyncMetaTable(attachedDatabase, alias);
  }
}

class SyncMetaData extends DataClass implements Insertable<SyncMetaData> {
  final String channelId;

  /// The newest ULID through which history is *contiguously* cached for this
  /// channel — the reconnect resume cursor. **SINGLE WRITER: the pager loop
  /// only** (`advanceHistoryContiguous`). Live W3 inserts never touch it; that
  /// separation is the round-4 fix (MAX(serverUlid) had two writers and lost
  /// messages on an interrupted sync). NULL = nothing fetched yet → page from
  /// the start.
  final String? historyContiguousThrough;
  const SyncMetaData({required this.channelId, this.historyContiguousThrough});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['channel_id'] = Variable<String>(channelId);
    if (!nullToAbsent || historyContiguousThrough != null) {
      map['history_contiguous_through'] = Variable<String>(
        historyContiguousThrough,
      );
    }
    return map;
  }

  SyncMetaCompanion toCompanion(bool nullToAbsent) {
    return SyncMetaCompanion(
      channelId: Value(channelId),
      historyContiguousThrough: historyContiguousThrough == null && nullToAbsent
          ? const Value.absent()
          : Value(historyContiguousThrough),
    );
  }

  factory SyncMetaData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncMetaData(
      channelId: serializer.fromJson<String>(json['channelId']),
      historyContiguousThrough: serializer.fromJson<String?>(
        json['historyContiguousThrough'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'channelId': serializer.toJson<String>(channelId),
      'historyContiguousThrough': serializer.toJson<String?>(
        historyContiguousThrough,
      ),
    };
  }

  SyncMetaData copyWith({
    String? channelId,
    Value<String?> historyContiguousThrough = const Value.absent(),
  }) => SyncMetaData(
    channelId: channelId ?? this.channelId,
    historyContiguousThrough: historyContiguousThrough.present
        ? historyContiguousThrough.value
        : this.historyContiguousThrough,
  );
  SyncMetaData copyWithCompanion(SyncMetaCompanion data) {
    return SyncMetaData(
      channelId: data.channelId.present ? data.channelId.value : this.channelId,
      historyContiguousThrough: data.historyContiguousThrough.present
          ? data.historyContiguousThrough.value
          : this.historyContiguousThrough,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetaData(')
          ..write('channelId: $channelId, ')
          ..write('historyContiguousThrough: $historyContiguousThrough')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(channelId, historyContiguousThrough);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncMetaData &&
          other.channelId == this.channelId &&
          other.historyContiguousThrough == this.historyContiguousThrough);
}

class SyncMetaCompanion extends UpdateCompanion<SyncMetaData> {
  final Value<String> channelId;
  final Value<String?> historyContiguousThrough;
  final Value<int> rowid;
  const SyncMetaCompanion({
    this.channelId = const Value.absent(),
    this.historyContiguousThrough = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncMetaCompanion.insert({
    required String channelId,
    this.historyContiguousThrough = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : channelId = Value(channelId);
  static Insertable<SyncMetaData> custom({
    Expression<String>? channelId,
    Expression<String>? historyContiguousThrough,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (channelId != null) 'channel_id': channelId,
      if (historyContiguousThrough != null)
        'history_contiguous_through': historyContiguousThrough,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncMetaCompanion copyWith({
    Value<String>? channelId,
    Value<String?>? historyContiguousThrough,
    Value<int>? rowid,
  }) {
    return SyncMetaCompanion(
      channelId: channelId ?? this.channelId,
      historyContiguousThrough:
          historyContiguousThrough ?? this.historyContiguousThrough,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (channelId.present) {
      map['channel_id'] = Variable<String>(channelId.value);
    }
    if (historyContiguousThrough.present) {
      map['history_contiguous_through'] = Variable<String>(
        historyContiguousThrough.value,
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetaCompanion(')
          ..write('channelId: $channelId, ')
          ..write('historyContiguousThrough: $historyContiguousThrough, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$DriftCache extends GeneratedDatabase {
  _$DriftCache(QueryExecutor e) : super(e);
  $DriftCacheManager get managers => $DriftCacheManager(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $ChannelsTable channels = $ChannelsTable(this);
  late final $SyncMetaTable syncMeta = $SyncMetaTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    messages,
    channels,
    syncMeta,
  ];
}

typedef $$MessagesTableCreateCompanionBuilder =
    MessagesCompanion Function({
      required String clientTempId,
      Value<String?> serverUlid,
      required String channelId,
      Value<String?> senderUserId,
      required String senderKind,
      Value<String?> senderLabel,
      required String kind,
      required String body,
      Value<String?> replyToId,
      required int createdAt,
      Value<int> localSeq,
      required String deliveryState,
      Value<String?> sig,
      Value<String?> senderPubkey,
      Value<int?> signedAtMs,
      Value<int?> keyVersion,
      Value<String?> signedClientMsgId,
      Value<int?> originCryptoValid,
      Value<int> rowid,
    });
typedef $$MessagesTableUpdateCompanionBuilder =
    MessagesCompanion Function({
      Value<String> clientTempId,
      Value<String?> serverUlid,
      Value<String> channelId,
      Value<String?> senderUserId,
      Value<String> senderKind,
      Value<String?> senderLabel,
      Value<String> kind,
      Value<String> body,
      Value<String?> replyToId,
      Value<int> createdAt,
      Value<int> localSeq,
      Value<String> deliveryState,
      Value<String?> sig,
      Value<String?> senderPubkey,
      Value<int?> signedAtMs,
      Value<int?> keyVersion,
      Value<String?> signedClientMsgId,
      Value<int?> originCryptoValid,
      Value<int> rowid,
    });

class $$MessagesTableFilterComposer
    extends Composer<_$DriftCache, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get clientTempId => $composableBuilder(
    column: $table.clientTempId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverUlid => $composableBuilder(
    column: $table.serverUlid,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderUserId => $composableBuilder(
    column: $table.senderUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderKind => $composableBuilder(
    column: $table.senderKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderLabel => $composableBuilder(
    column: $table.senderLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replyToId => $composableBuilder(
    column: $table.replyToId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get localSeq => $composableBuilder(
    column: $table.localSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deliveryState => $composableBuilder(
    column: $table.deliveryState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sig => $composableBuilder(
    column: $table.sig,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderPubkey => $composableBuilder(
    column: $table.senderPubkey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get signedAtMs => $composableBuilder(
    column: $table.signedAtMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get keyVersion => $composableBuilder(
    column: $table.keyVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get signedClientMsgId => $composableBuilder(
    column: $table.signedClientMsgId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get originCryptoValid => $composableBuilder(
    column: $table.originCryptoValid,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MessagesTableOrderingComposer
    extends Composer<_$DriftCache, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get clientTempId => $composableBuilder(
    column: $table.clientTempId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverUlid => $composableBuilder(
    column: $table.serverUlid,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderUserId => $composableBuilder(
    column: $table.senderUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderKind => $composableBuilder(
    column: $table.senderKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderLabel => $composableBuilder(
    column: $table.senderLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replyToId => $composableBuilder(
    column: $table.replyToId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get localSeq => $composableBuilder(
    column: $table.localSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deliveryState => $composableBuilder(
    column: $table.deliveryState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sig => $composableBuilder(
    column: $table.sig,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderPubkey => $composableBuilder(
    column: $table.senderPubkey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get signedAtMs => $composableBuilder(
    column: $table.signedAtMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get keyVersion => $composableBuilder(
    column: $table.keyVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get signedClientMsgId => $composableBuilder(
    column: $table.signedClientMsgId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get originCryptoValid => $composableBuilder(
    column: $table.originCryptoValid,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MessagesTableAnnotationComposer
    extends Composer<_$DriftCache, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get clientTempId => $composableBuilder(
    column: $table.clientTempId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverUlid => $composableBuilder(
    column: $table.serverUlid,
    builder: (column) => column,
  );

  GeneratedColumn<String> get channelId =>
      $composableBuilder(column: $table.channelId, builder: (column) => column);

  GeneratedColumn<String> get senderUserId => $composableBuilder(
    column: $table.senderUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get senderKind => $composableBuilder(
    column: $table.senderKind,
    builder: (column) => column,
  );

  GeneratedColumn<String> get senderLabel => $composableBuilder(
    column: $table.senderLabel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get replyToId =>
      $composableBuilder(column: $table.replyToId, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get localSeq =>
      $composableBuilder(column: $table.localSeq, builder: (column) => column);

  GeneratedColumn<String> get deliveryState => $composableBuilder(
    column: $table.deliveryState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get sig =>
      $composableBuilder(column: $table.sig, builder: (column) => column);

  GeneratedColumn<String> get senderPubkey => $composableBuilder(
    column: $table.senderPubkey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get signedAtMs => $composableBuilder(
    column: $table.signedAtMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get keyVersion => $composableBuilder(
    column: $table.keyVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get signedClientMsgId => $composableBuilder(
    column: $table.signedClientMsgId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get originCryptoValid => $composableBuilder(
    column: $table.originCryptoValid,
    builder: (column) => column,
  );
}

class $$MessagesTableTableManager
    extends
        RootTableManager<
          _$DriftCache,
          $MessagesTable,
          MessageRow,
          $$MessagesTableFilterComposer,
          $$MessagesTableOrderingComposer,
          $$MessagesTableAnnotationComposer,
          $$MessagesTableCreateCompanionBuilder,
          $$MessagesTableUpdateCompanionBuilder,
          (
            MessageRow,
            BaseReferences<_$DriftCache, $MessagesTable, MessageRow>,
          ),
          MessageRow,
          PrefetchHooks Function()
        > {
  $$MessagesTableTableManager(_$DriftCache db, $MessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> clientTempId = const Value.absent(),
                Value<String?> serverUlid = const Value.absent(),
                Value<String> channelId = const Value.absent(),
                Value<String?> senderUserId = const Value.absent(),
                Value<String> senderKind = const Value.absent(),
                Value<String?> senderLabel = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<String?> replyToId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> localSeq = const Value.absent(),
                Value<String> deliveryState = const Value.absent(),
                Value<String?> sig = const Value.absent(),
                Value<String?> senderPubkey = const Value.absent(),
                Value<int?> signedAtMs = const Value.absent(),
                Value<int?> keyVersion = const Value.absent(),
                Value<String?> signedClientMsgId = const Value.absent(),
                Value<int?> originCryptoValid = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion(
                clientTempId: clientTempId,
                serverUlid: serverUlid,
                channelId: channelId,
                senderUserId: senderUserId,
                senderKind: senderKind,
                senderLabel: senderLabel,
                kind: kind,
                body: body,
                replyToId: replyToId,
                createdAt: createdAt,
                localSeq: localSeq,
                deliveryState: deliveryState,
                sig: sig,
                senderPubkey: senderPubkey,
                signedAtMs: signedAtMs,
                keyVersion: keyVersion,
                signedClientMsgId: signedClientMsgId,
                originCryptoValid: originCryptoValid,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String clientTempId,
                Value<String?> serverUlid = const Value.absent(),
                required String channelId,
                Value<String?> senderUserId = const Value.absent(),
                required String senderKind,
                Value<String?> senderLabel = const Value.absent(),
                required String kind,
                required String body,
                Value<String?> replyToId = const Value.absent(),
                required int createdAt,
                Value<int> localSeq = const Value.absent(),
                required String deliveryState,
                Value<String?> sig = const Value.absent(),
                Value<String?> senderPubkey = const Value.absent(),
                Value<int?> signedAtMs = const Value.absent(),
                Value<int?> keyVersion = const Value.absent(),
                Value<String?> signedClientMsgId = const Value.absent(),
                Value<int?> originCryptoValid = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion.insert(
                clientTempId: clientTempId,
                serverUlid: serverUlid,
                channelId: channelId,
                senderUserId: senderUserId,
                senderKind: senderKind,
                senderLabel: senderLabel,
                kind: kind,
                body: body,
                replyToId: replyToId,
                createdAt: createdAt,
                localSeq: localSeq,
                deliveryState: deliveryState,
                sig: sig,
                senderPubkey: senderPubkey,
                signedAtMs: signedAtMs,
                keyVersion: keyVersion,
                signedClientMsgId: signedClientMsgId,
                originCryptoValid: originCryptoValid,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$DriftCache,
      $MessagesTable,
      MessageRow,
      $$MessagesTableFilterComposer,
      $$MessagesTableOrderingComposer,
      $$MessagesTableAnnotationComposer,
      $$MessagesTableCreateCompanionBuilder,
      $$MessagesTableUpdateCompanionBuilder,
      (MessageRow, BaseReferences<_$DriftCache, $MessagesTable, MessageRow>),
      MessageRow,
      PrefetchHooks Function()
    >;
typedef $$ChannelsTableCreateCompanionBuilder =
    ChannelsCompanion Function({
      required String id,
      required String name,
      required String kind,
      Value<String?> aikoChannel,
      Value<int> rowid,
    });
typedef $$ChannelsTableUpdateCompanionBuilder =
    ChannelsCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> kind,
      Value<String?> aikoChannel,
      Value<int> rowid,
    });

class $$ChannelsTableFilterComposer
    extends Composer<_$DriftCache, $ChannelsTable> {
  $$ChannelsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get aikoChannel => $composableBuilder(
    column: $table.aikoChannel,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ChannelsTableOrderingComposer
    extends Composer<_$DriftCache, $ChannelsTable> {
  $$ChannelsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get aikoChannel => $composableBuilder(
    column: $table.aikoChannel,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ChannelsTableAnnotationComposer
    extends Composer<_$DriftCache, $ChannelsTable> {
  $$ChannelsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get aikoChannel => $composableBuilder(
    column: $table.aikoChannel,
    builder: (column) => column,
  );
}

class $$ChannelsTableTableManager
    extends
        RootTableManager<
          _$DriftCache,
          $ChannelsTable,
          ChannelRow,
          $$ChannelsTableFilterComposer,
          $$ChannelsTableOrderingComposer,
          $$ChannelsTableAnnotationComposer,
          $$ChannelsTableCreateCompanionBuilder,
          $$ChannelsTableUpdateCompanionBuilder,
          (
            ChannelRow,
            BaseReferences<_$DriftCache, $ChannelsTable, ChannelRow>,
          ),
          ChannelRow,
          PrefetchHooks Function()
        > {
  $$ChannelsTableTableManager(_$DriftCache db, $ChannelsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChannelsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChannelsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChannelsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String?> aikoChannel = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChannelsCompanion(
                id: id,
                name: name,
                kind: kind,
                aikoChannel: aikoChannel,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String kind,
                Value<String?> aikoChannel = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ChannelsCompanion.insert(
                id: id,
                name: name,
                kind: kind,
                aikoChannel: aikoChannel,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ChannelsTableProcessedTableManager =
    ProcessedTableManager<
      _$DriftCache,
      $ChannelsTable,
      ChannelRow,
      $$ChannelsTableFilterComposer,
      $$ChannelsTableOrderingComposer,
      $$ChannelsTableAnnotationComposer,
      $$ChannelsTableCreateCompanionBuilder,
      $$ChannelsTableUpdateCompanionBuilder,
      (ChannelRow, BaseReferences<_$DriftCache, $ChannelsTable, ChannelRow>),
      ChannelRow,
      PrefetchHooks Function()
    >;
typedef $$SyncMetaTableCreateCompanionBuilder =
    SyncMetaCompanion Function({
      required String channelId,
      Value<String?> historyContiguousThrough,
      Value<int> rowid,
    });
typedef $$SyncMetaTableUpdateCompanionBuilder =
    SyncMetaCompanion Function({
      Value<String> channelId,
      Value<String?> historyContiguousThrough,
      Value<int> rowid,
    });

class $$SyncMetaTableFilterComposer
    extends Composer<_$DriftCache, $SyncMetaTable> {
  $$SyncMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get historyContiguousThrough => $composableBuilder(
    column: $table.historyContiguousThrough,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncMetaTableOrderingComposer
    extends Composer<_$DriftCache, $SyncMetaTable> {
  $$SyncMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get channelId => $composableBuilder(
    column: $table.channelId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get historyContiguousThrough => $composableBuilder(
    column: $table.historyContiguousThrough,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncMetaTableAnnotationComposer
    extends Composer<_$DriftCache, $SyncMetaTable> {
  $$SyncMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get channelId =>
      $composableBuilder(column: $table.channelId, builder: (column) => column);

  GeneratedColumn<String> get historyContiguousThrough => $composableBuilder(
    column: $table.historyContiguousThrough,
    builder: (column) => column,
  );
}

class $$SyncMetaTableTableManager
    extends
        RootTableManager<
          _$DriftCache,
          $SyncMetaTable,
          SyncMetaData,
          $$SyncMetaTableFilterComposer,
          $$SyncMetaTableOrderingComposer,
          $$SyncMetaTableAnnotationComposer,
          $$SyncMetaTableCreateCompanionBuilder,
          $$SyncMetaTableUpdateCompanionBuilder,
          (
            SyncMetaData,
            BaseReferences<_$DriftCache, $SyncMetaTable, SyncMetaData>,
          ),
          SyncMetaData,
          PrefetchHooks Function()
        > {
  $$SyncMetaTableTableManager(_$DriftCache db, $SyncMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> channelId = const Value.absent(),
                Value<String?> historyContiguousThrough = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncMetaCompanion(
                channelId: channelId,
                historyContiguousThrough: historyContiguousThrough,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String channelId,
                Value<String?> historyContiguousThrough = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncMetaCompanion.insert(
                channelId: channelId,
                historyContiguousThrough: historyContiguousThrough,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$DriftCache,
      $SyncMetaTable,
      SyncMetaData,
      $$SyncMetaTableFilterComposer,
      $$SyncMetaTableOrderingComposer,
      $$SyncMetaTableAnnotationComposer,
      $$SyncMetaTableCreateCompanionBuilder,
      $$SyncMetaTableUpdateCompanionBuilder,
      (
        SyncMetaData,
        BaseReferences<_$DriftCache, $SyncMetaTable, SyncMetaData>,
      ),
      SyncMetaData,
      PrefetchHooks Function()
    >;

class $DriftCacheManager {
  final _$DriftCache _db;
  $DriftCacheManager(this._db);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$ChannelsTableTableManager get channels =>
      $$ChannelsTableTableManager(_db, _db.channels);
  $$SyncMetaTableTableManager get syncMeta =>
      $$SyncMetaTableTableManager(_db, _db.syncMeta);
}
