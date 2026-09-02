/// Immutable envelope model and hand-written JSON serialization.
///
/// Pure Dart — no Flutter imports — so the codec is testable without a device.
library;

import 'dart:convert' show base64Decode, base64Encode;
import 'dart:typed_data';

import 'errors.dart';

/// Wire JSON keys for envelope fields (snake_case per SPEC section 1.1).
///
/// Centralized so the required-field table and parser cannot drift apart.
abstract final class _EnvelopeKeys {
  static const id = 'id';
  static const part = 'part';
  static const entityType = 'entity_type';
  static const createdAtMs = 'created_at_ms';
  static const lastEditedAtMs = 'last_edited_at_ms';
  static const revision = 'revision';
  static const sourceId = 'source_id';
  static const flags = 'flags';
  static const schemaVersion = 'schema_version';
  static const payloadEncoding = 'payload_encoding';
  static const payload = 'payload';
  static const serverSeq = 'server_seq';
}

/// A single sync envelope as defined in SPEC section 1.1.
///
/// Three deliberate differences from the server-side table:
///
/// - No [userId]: the owner is taken from the bearer token (`sub`), not the
///   envelope JSON. A stray `user_id` key on the wire is ignored (SPEC section
///   6).
/// - [serverSeq] is optional (`int?`). It is set on envelopes from pull and
///   live responses; when pushing, it is `null` and omitted from [toJson].
/// - [payload] is [Uint8List], not [String]. The wire carries opaque bytes as
///   base64; treating payload as text would break on the first non-UTF-8
///   content.
final class Envelope {
  /// Creates an envelope with a defensive copy of [payload].
  Envelope({
    required this.id,
    required this.part,
    required this.entityType,
    required this.createdAtMs,
    required this.lastEditedAtMs,
    required this.revision,
    required this.sourceId,
    required this.flags,
    required this.schemaVersion,
    required this.payloadEncoding,
    required Uint8List payload,
    this.serverSeq,
  }) : payload = Uint8List.fromList(payload);

  /// Stable entity identifier (UUID string on the wire).
  final String id;

  /// Envelope part name (round 1 always `full`).
  final String part;

  /// Logical entity type, for example `counter_operation`.
  final String entityType;

  /// Creation time as Unix epoch milliseconds.
  final int createdAtMs;

  /// Last edit time as Unix epoch milliseconds.
  final int lastEditedAtMs;

  /// Monotonic revision within the entity, starting at 1.
  final int revision;

  /// Originating device or client identifier.
  final String sourceId;

  /// Bit flags reserved for future use (round 1 always 0).
  final int flags;

  /// Payload schema version for the entity adapter.
  final int schemaVersion;

  /// Hint for decoding [payload], for example `json`.
  final String payloadEncoding;

  /// Opaque content bytes; the library does not interpret encoding or UTF-8.
  final Uint8List payload;

  /// Server-assigned sequence after persistence; absent when pushing.
  final int? serverSeq;

  /// Parses [json] into an [Envelope], ignoring unknown keys (SPEC section 6).
  factory Envelope.fromJson(Map<String, Object?> json) {
    return Envelope(
      id: _requireString(json, _EnvelopeKeys.id),
      part: _requireString(json, _EnvelopeKeys.part),
      entityType: _requireString(json, _EnvelopeKeys.entityType),
      createdAtMs: _requireInt(json, _EnvelopeKeys.createdAtMs),
      lastEditedAtMs: _requireInt(json, _EnvelopeKeys.lastEditedAtMs),
      revision: _requireInt(json, _EnvelopeKeys.revision),
      sourceId: _requireString(json, _EnvelopeKeys.sourceId),
      flags: _requireInt(json, _EnvelopeKeys.flags),
      schemaVersion: _requireInt(json, _EnvelopeKeys.schemaVersion),
      payloadEncoding: _requireString(json, _EnvelopeKeys.payloadEncoding),
      payload: _requirePayload(json),
      serverSeq: _optionalInt(json, _EnvelopeKeys.serverSeq),
    );
  }

  /// Serializes this envelope to wire JSON (snake_case keys).
  Map<String, Object?> toJson() {
    // RFC 4648 section 4 (standard alphabet with +, /, and = padding).
    // Go's encoding/base64.StdEncoding uses the same alphabet; section 5
    // (URL-safe) diverges on bytes containing + or /.
    final encodedPayload = base64Encode(payload);

    final map = <String, Object?>{
      _EnvelopeKeys.id: id,
      _EnvelopeKeys.part: part,
      _EnvelopeKeys.entityType: entityType,
      _EnvelopeKeys.createdAtMs: createdAtMs,
      _EnvelopeKeys.lastEditedAtMs: lastEditedAtMs,
      _EnvelopeKeys.revision: revision,
      _EnvelopeKeys.sourceId: sourceId,
      _EnvelopeKeys.flags: flags,
      _EnvelopeKeys.schemaVersion: schemaVersion,
      _EnvelopeKeys.payloadEncoding: payloadEncoding,
      _EnvelopeKeys.payload: encodedPayload,
    };

    final seq = serverSeq;
    if (seq != null) {
      map[_EnvelopeKeys.serverSeq] = seq;
    }

    return map;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Envelope) {
      return false;
    }
    if (id != other.id ||
        part != other.part ||
        entityType != other.entityType ||
        createdAtMs != other.createdAtMs ||
        lastEditedAtMs != other.lastEditedAtMs ||
        revision != other.revision ||
        sourceId != other.sourceId ||
        flags != other.flags ||
        schemaVersion != other.schemaVersion ||
        payloadEncoding != other.payloadEncoding ||
        serverSeq != other.serverSeq ||
        payload.length != other.payload.length) {
      return false;
    }
    for (var i = 0; i < payload.length; i++) {
      if (payload[i] != other.payload[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    id,
    part,
    entityType,
    createdAtMs,
    lastEditedAtMs,
    revision,
    sourceId,
    flags,
    schemaVersion,
    payloadEncoding,
    serverSeq,
    Object.hashAll(payload),
  );

  @override
  String toString() =>
      'Envelope(id: $id, entityType: $entityType, revision: $revision, '
      'serverSeq: $serverSeq)';
}

String _requireString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) {
    throw UlsyncProtocolException(
      'Missing or null required field: $field',
      field: field,
    );
  }
  if (value is! String) {
    throw UlsyncProtocolException(
      'Expected string for field: $field',
      field: field,
    );
  }
  return value;
}

int _requireInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) {
    throw UlsyncProtocolException(
      'Missing or null required field: $field',
      field: field,
    );
  }
  if (value is! int) {
    throw UlsyncProtocolException(
      'Expected integer for field: $field',
      field: field,
    );
  }
  return value;
}

int? _optionalInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) {
    return null;
  }
  if (value is! int) {
    throw UlsyncProtocolException(
      'Expected integer for field: $field',
      field: field,
    );
  }
  return value;
}

Uint8List _requirePayload(Map<String, Object?> json) {
  final field = _EnvelopeKeys.payload;
  final value = json[field];
  if (value == null) {
    throw UlsyncProtocolException(
      'Missing or null required field: $field',
      field: field,
    );
  }
  if (value is! String) {
    throw UlsyncProtocolException(
      'Expected string for field: $field',
      field: field,
    );
  }
  // RFC 4648 section 4 only — reject URL alphabet (- and _) before decode,
  // because dart:convert base64Decode accepts some non-standard characters.
  if (!_standardBase64Pattern.hasMatch(value)) {
    throw UlsyncProtocolException(
      'Invalid base64 for field: $field',
      field: field,
    );
  }
  try {
    // RFC 4648 section 4 — must match Go StdEncoding, not the URL alphabet.
    return base64Decode(value);
  } on FormatException {
    throw UlsyncProtocolException(
      'Invalid base64 for field: $field',
      field: field,
    );
  }
}

/// Characters allowed in RFC 4648 section 4 base64 (standard alphabet).
final _standardBase64Pattern = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');
