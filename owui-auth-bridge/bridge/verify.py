"""Round-trip identity verification for the Open WebUI → honeybot auth bridge.

The problem this solves: Open WebUI forwards the signed-in user's identity
as X-OpenWebUI-User-* headers. We must NOT simply trust those headers
(inbound filtering) — a spoofed or mis-forwarded header would mint a
verified session for the WRONG user and hand them someone else's
credentials. Instead we resolve identity from authoritative sources and
reject on any mismatch (round-trip verification):

  1. Take ONLY the claimed email from the header — never the claimed UID.
  2. Resolve the UID from Slack (users.lookupByEmail). Slack is our
     authoritative identity store; the UID we mint against comes from
     Slack, not from the request.
  3. Bidirectionally confirm: the Slack account must be active, human
     (not a bot), and its canonical profile email must match the claim.
  4. Re-check the allowed domain on the SLACK-returned email, not the
     header.
  5. Optionally (when configured) confirm the (user_id, email) pair is a
     real account in Open WebUI's own DB — an authoritative round-trip
     that defends the email claim itself.

Any failure → not verified. The caller forwards the request WITHOUT a
session key, so the session stays unverified and falls back to OTP —
fail closed, never mint for an unconfirmed identity.

This module is pure logic: the actual HTTP calls are injected as callables
so the verification decisions are fully unit-testable without a network.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Callable, Optional

_SLACK_UID_RE = re.compile(r"^[UW][A-Z0-9]{8,}$")

# slack_lookup(email) -> Slack user dict (the "user" object from
#   users.lookupByEmail) or None on not-found / error.
SlackLookup = Callable[[str], Optional[dict]]
# owui_lookup(user_id) -> Open WebUI user dict (with "email") or None.
OwuiLookup = Callable[[str], Optional[dict]]


@dataclass(frozen=True)
class Identity:
    slack_uid: str
    email: str  # the verified, canonical email (from Slack), not the header


@dataclass(frozen=True)
class VerifyResult:
    ok: bool
    identity: Optional[Identity]
    reason: str  # human-readable; logged, never sent to the client


class Verifier:
    def __init__(
        self,
        *,
        allowed_domains: set[str],
        slack_lookup: SlackLookup,
        owui_lookup: Optional[OwuiLookup] = None,
        require_owui: bool = False,
    ):
        # Lower-cased domain allow-list, e.g. {"honeymanenterprises.com"}.
        self._domains = {d.strip().lower() for d in allowed_domains if d.strip()}
        self._slack_lookup = slack_lookup
        self._owui_lookup = owui_lookup
        # If True, an unconfigured/failed Open WebUI round-trip is a hard
        # reject (strictest). If False, we proceed on the Slack round-trip
        # alone (with a caller-side warning) when OWUI lookup isn't wired.
        self._require_owui = require_owui

    def verify(self, *, claimed_email: str, claimed_user_id: str) -> VerifyResult:
        email = (claimed_email or "").strip().lower()
        if not email or "@" not in email:
            return VerifyResult(False, None, "no/invalid claimed email")

        if not self._domain_ok(email):
            return VerifyResult(False, None, f"claimed email domain not allowed: {email}")

        # --- Authoritative round-trip #1: Slack (email -> uid) --------------
        user = self._slack_lookup(email)
        if not user:
            return VerifyResult(False, None, f"Slack has no user for {email}")
        if user.get("deleted"):
            return VerifyResult(False, None, f"Slack account deleted: {email}")
        if user.get("is_bot") or user.get("id") == "USLACKBOT":
            return VerifyResult(False, None, f"Slack account is a bot: {email}")

        uid = (user.get("id") or "").strip()
        if not _SLACK_UID_RE.match(uid):
            return VerifyResult(False, None, f"Slack returned a non-UID id: {uid!r}")

        # Bidirectional: the email Slack has on file must match the claim,
        # and must ALSO be in an allowed domain (defends against a Slack
        # profile whose email drifted out of the org).
        slack_email = (user.get("profile", {}).get("email") or "").strip().lower()
        if slack_email and slack_email != email:
            return VerifyResult(
                False, None,
                f"Slack email {slack_email} != claimed {email} (mismatch)",
            )
        canonical_email = slack_email or email
        if not self._domain_ok(canonical_email):
            return VerifyResult(False, None, f"Slack email domain not allowed: {canonical_email}")

        # --- Authoritative round-trip #2: Open WebUI (defends the claim) ----
        # Confirms the (user_id, email) the request presented is a real,
        # consistent account in Open WebUI's DB — not a fabricated header.
        if self._owui_lookup is not None:
            owui_user = self._owui_lookup((claimed_user_id or "").strip())
            if not owui_user:
                return VerifyResult(False, None, "Open WebUI has no such user_id")
            owui_email = (owui_user.get("email") or "").strip().lower()
            if owui_email != email:
                return VerifyResult(
                    False, None,
                    f"Open WebUI email {owui_email} != claimed {email} (mismatch)",
                )
        elif self._require_owui:
            return VerifyResult(False, None, "Open WebUI round-trip required but not configured")

        return VerifyResult(True, Identity(slack_uid=uid, email=canonical_email), "verified")

    def _domain_ok(self, email: str) -> bool:
        if not self._domains:
            return False  # empty allow-list = deny all (fail closed)
        domain = email.rsplit("@", 1)[-1]
        return domain in self._domains
