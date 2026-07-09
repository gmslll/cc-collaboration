String cleanedIdentity(String identity) => identity.trim();

String identityLookupKey(String identity) =>
    cleanedIdentity(identity).toLowerCase();

bool sameIdentity(String left, String right) {
  final l = identityLookupKey(left);
  final r = identityLookupKey(right);
  return l.isNotEmpty && l == r;
}
