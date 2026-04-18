# HubSpot skill \u2014 seed examples

This directory holds worked examples the skill uses as few-shot prompts for
Hermes. v1 has none yet \u2014 the install/auth flow is deterministic bash, not
an LLM-decided action.

v2+ will add files like:
- `find-contact-by-email.md` \u2014 input: "find jane@acme.com" \u2192 `hs api get ...`
- `list-deals-closing-this-month.md`
- `log-note-on-contact.md` (write, with confirmation block)
