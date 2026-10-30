/// What happens to a typed handle before it leaves the device. Shared by every
/// screen that takes one (sign-up, the island's claim step, Settings), so the
/// three can't drift. Handles are otherwise free text (island #436, Nick
/// 2026-10-28: the island adds no character rules).
library;

/// The island's own bound on a handle (`PATCH /v1/me`: 1 to 64 characters).
/// Deliberately no stricter: a rule only the app enforced would be its own
/// drift from the island.
const kMaxHandleLength = 64;

/// A handle's length as the island (Python, pydantic `max_length`) counts it:
/// in CODE POINTS. Dart's `String.length` counts UTF-16 units and a
/// TextField's `maxLength` counts grapheme clusters, so either would refuse
/// emoji handles the island takes, or pass ones it 422s. Same class as
/// RFC-0001's codec bug.
int handleLength(String handle) => handle.runes.length;

/// What the person meant by what they typed. Every handle field shows an "@"
/// in front of the input, so people type one too. The first outside user did:
/// "@armbot" was stored, and shown as "@@armbot". Leading "@"s are that
/// prefix, never part of the handle. Nothing else is changed.
String normalizeHandle(String typed) =>
    typed.trim().replaceFirst(RegExp(r'^@+'), '').trim();
