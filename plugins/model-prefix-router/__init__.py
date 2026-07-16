"""
Model Prefix Router — per-message model switching via message prefix.

When a user's message starts with a recognized model name/alias, this plugin:
1. Strips the prefix from the message text
2. Sets a session-level model override on the gateway (same mechanism as /model)
3. The override persists for the thread/session (use /model to switch back)

Examples:
  "opus what is the meaning of life"  →  routes to Claude Opus
  "gpt5 explain quantum computing"    →  routes to GPT-5
  "gpt-5.6-sol write me a poem"       →  routes to GPT-5.6 Sol
  "sonnet fix this bug"               →  routes to Claude Sonnet
  "haiku summarize this"              →  routes to Claude Haiku

The prefix matching is case-insensitive and supports:
- Built-in aliases: opus, sonnet, haiku, gpt5, gpt, grok, gemini, deepseek, etc.
- Full model names: gpt-5.6-sol, claude-opus-4-6, o3-pro, etc.
- Custom aliases from config.yaml model_aliases section
"""

from __future__ import annotations

import logging
import re
from typing import Optional

logger = logging.getLogger("plugin.model-prefix-router")

# Lazy-loaded on first call
_ALIASES: Optional[dict] = None
_DIRECT_ALIASES: Optional[dict] = None


def _load_aliases():
    """Load model aliases from hermes_cli.model_switch."""
    global _ALIASES, _DIRECT_ALIASES
    try:
        from hermes_cli.model_switch import MODEL_ALIASES
        _ALIASES = {k.lower(): v for k, v in MODEL_ALIASES.items()}
        try:
            from hermes_cli.model_switch import load_user_direct_aliases
            _DIRECT_ALIASES = {k.lower(): v for k, v in load_user_direct_aliases().items()}
        except Exception:
            _DIRECT_ALIASES = {}
    except ImportError:
        logger.warning("Could not import model_switch — prefix routing disabled")
        _ALIASES = {}
        _DIRECT_ALIASES = {}


def _try_resolve_model(prefix: str) -> Optional[dict]:
    """Try to resolve a prefix to a model+provider.

    Returns {"model": ..., "provider": ...} or None if no match.

    Uses switch_model() for all resolution — it handles built-in aliases,
    user aliases, and full model names uniformly, and returns the exact
    model string + provider the gateway needs.
    """
    key = prefix.lower().strip()

    try:
        from hermes_cli.model_switch import switch_model
        from hermes_cli.config import load_config
        cfg = load_config() or {}
        model_cfg = cfg.get("model", {})
        if isinstance(model_cfg, str):
            model_cfg = {"default": model_cfg}

        result = switch_model(
            raw_input=key,
            current_provider=model_cfg.get("provider", ""),
            current_model=model_cfg.get("default", ""),
            current_base_url=model_cfg.get("base_url", ""),
            current_api_key=model_cfg.get("api_key", ""),
        )
        if result and getattr(result, "success", True) and result.new_model:
            # Only accept if switch_model actually resolved via a known alias
            # or the model name changed from the current one. Without this
            # guard, switch_model echoes ANY string back as a "model name"
            # (e.g. "you" → model=you) which then 404s at the provider.
            resolved_alias = getattr(result, "resolved_via_alias", "")
            if not resolved_alias and result.new_model == key:
                # Not a real alias match — just echo. Reject.
                return None
            return {
                "provider": result.target_provider,
                "model": result.new_model,
                "api_key": getattr(result, "api_key", "") or "",
                "base_url": getattr(result, "base_url", "") or "",
            }
    except Exception as e:
        logger.debug("switch_model resolution failed for %r: %s", key, e)

    return None


# Pattern: first word (allowing hyphens and dots for model names like gpt-5.6-sol)
_PREFIX_RE = re.compile(r'^([a-zA-Z][a-zA-Z0-9._-]*)\s+(.*)', re.DOTALL)

# Common English words that could collide with model names
_SKIP_WORDS = frozenset({
    "i", "a", "an", "the", "is", "it", "my", "me", "we", "us",
    "he", "she", "hi", "hey", "hello", "ok", "yes", "no", "not",
    "do", "did", "can", "how", "what", "when", "where", "why",
    "who", "which", "that", "this", "are", "was", "will", "would",
    "could", "should", "has", "have", "had", "if", "or", "and",
    "but", "so", "yet", "for", "to", "of", "in", "on", "at",
    "by", "up", "out", "off", "all", "any", "let", "set", "get",
    "put", "run", "use", "try", "ask", "say", "see", "go", "new",
    "also", "just", "help", "show", "list", "find", "make",
    "please", "thanks", "check", "look", "give", "take",
})


def _handle_pre_dispatch(*, event, gateway, **kwargs):
    """Plugin hook: intercept messages and apply per-message model routing."""
    text = getattr(event, "text", None)
    if not text or not text.strip():
        return None

    text = text.strip()
    m = _PREFIX_RE.match(text)
    if not m:
        return None

    prefix = m.group(1)
    rest = m.group(2).strip()

    # Don't match if rest is empty
    if not rest:
        return None

    # Skip common English words
    if prefix.lower() in _SKIP_WORDS:
        return None

    # Try to resolve the prefix as a model
    resolved = _try_resolve_model(prefix)
    if not resolved:
        return None

    # Set the model override on the gateway
    source = getattr(event, "source", None)
    if source and gateway:
        session_key = None
        try:
            session_key = gateway._resolve_session_key(source)
        except Exception:
            try:
                platform = getattr(source, "platform", None)
                chat_id = getattr(source, "chat_id", "")
                thread_id = getattr(source, "thread_id", "")
                if platform and chat_id:
                    pval = platform.value if hasattr(platform, "value") else str(platform)
                    chat_type = getattr(source, "chat_type", "dm")
                    session_key = f"agent:main:{pval}:{chat_type}:{chat_id}:{thread_id}"
            except Exception:
                pass

        if session_key:
            override = {
                "model": resolved["model"],
                "provider": resolved.get("provider", ""),
                "api_key": resolved.get("api_key", ""),
                "base_url": resolved.get("base_url", ""),
            }
            gateway._session_model_overrides[session_key] = override

            # Evict cached agent so the new model takes effect
            try:
                gateway._evict_cached_agent(session_key)
            except Exception:
                pass

            logger.info(
                "Model prefix routing: %r → model=%s provider=%s (session=%s)",
                prefix, resolved["model"], resolved.get("provider", "?"),
                session_key[:60],
            )

            # Rewrite the message text without the prefix
            return {"action": "rewrite", "text": rest}

    return None


def register(ctx):
    """Plugin entry point — register the pre_gateway_dispatch hook."""
    ctx.register_hook("pre_gateway_dispatch", _handle_pre_dispatch)
