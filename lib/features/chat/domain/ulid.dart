/// Canonical ULID-case discipline (PR#7 cage-match finding 4).
///
/// The reconcile engine orders/compares server message ids with lexicographic
/// `String.compareTo` — the watermark monotonicity in `advanceHistoryContiguous`
/// and the history-pager progress guard both depend on it. That comparison is
/// only sound if every id is in CANONICAL ULID form: Crockford base32, UPPERCASE.
/// A lowercase letter sorts AFTER every uppercase one in ASCII, so a single
/// non-canonical id would silently break monotonicity (a row could appear to go
/// "backwards", advancing the watermark wrongly or hanging the pager).
///
/// We don't normalise on the hot path (that would hide a contract breach from
/// the gateway); instead we ASSERT canonical form at the comparison boundary so
/// a non-canonical id fails LOUDLY in debug/test rather than corrupting order in
/// production. The assert compiles out of release builds (zero runtime cost).
library;

/// True iff [id] is in canonical ULID case (no lowercase letters). Cheap; the
/// full Crockford-alphabet check is intentionally NOT done here — case is the
/// only property that breaks `compareTo` monotonicity, and it's the property a
/// careless producer is most likely to violate.
bool isCanonicalUlidCase(String id) => id == id.toUpperCase();

/// Debug-only guard: assert [id] is canonical-case before it feeds a
/// lexicographic compare. No-op in release builds.
void assertCanonicalUlid(String id, {String? context}) {
  assert(
    isCanonicalUlidCase(id),
    'non-canonical ULID case "$id"${context != null ? ' ($context)' : ''} — '
    'lexicographic compareTo monotonicity assumes UPPERCASE Crockford base32',
  );
}
