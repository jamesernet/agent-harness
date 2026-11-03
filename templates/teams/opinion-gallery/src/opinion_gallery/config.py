"""config.yml -> Config. Every key the runtime reads is a field here."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

import yaml

KNOWN_TOP_LEVEL = {"org", "feed", "provider", "personas", "debate", "output", "review", "guardrails", "run"}
PROVIDER_KINDS = {"openai", "anthropic", "fake"}
DEBATE_OUTCOMES = {"auto", "two-views"}


class ConfigError(ValueError):
    """A config.yml problem a person has to fix."""


def is_blank(value: Any) -> bool:
    """A value still written `<< like this >>` in the template."""
    return isinstance(value, str) and "<<" in value


@dataclass
class FeedSource:
    url: str
    name: str = ""


@dataclass
class FeedConfig:
    sources: list[FeedSource]
    sections: list[str]
    lookback_hours: int = 36
    max_stories: int = 40
    skip_seen_days: int = 3
    summary_chars: int = 600


@dataclass
class ProviderConfig:
    kind: str = "openai"
    base_url: str = ""
    model: str = ""
    api_key_env: str = ""
    json_mode: bool = False
    timeout_s: int = 120
    max_tokens: dict[str, int] = field(default_factory=lambda: {"triage": 2048, "draft": 4096, "debate": 4096})


@dataclass
class PersonasConfig:
    enabled: list[str]
    draft_threshold: int = 4
    max_drafts_per_persona: int = 2


@dataclass
class DebateConfig:
    enabled: bool = True
    max_participants: int = 3
    outcome: str = "auto"
    max_words_per_reply: int = 250


@dataclass
class GithubConfig:
    repo: str = ""
    labels: list[str] = field(default_factory=list)
    assignees: list[str] = field(default_factory=list)


@dataclass
class OutputConfig:
    drafts_dir: str
    disclosure: str
    github: GithubConfig


@dataclass
class ReviewConfig:
    reviewers: list[str]


@dataclass
class GuardrailsConfig:
    file: str = "guardrails.md"
    modified: bool = False


@dataclass
class RunConfig:
    state_file: str = "opinion-gallery/.state.json"
    timezone: str = "UTC"


@dataclass
class Config:
    org_name: str
    org_site: str
    feed: FeedConfig
    provider: ProviderConfig
    personas: PersonasConfig
    debate: DebateConfig
    output: OutputConfig
    review: ReviewConfig
    guardrails: GuardrailsConfig
    run: RunConfig
    warnings: list[str] = field(default_factory=list)

    def blanks(self) -> list[str]:
        """Dotted paths of every value still written `<< like this >>`."""
        out: list[str] = []
        if is_blank(self.org_name):
            out.append("org.name")
        if is_blank(self.org_site):
            out.append("org.site")
        for i, s in enumerate(self.feed.sources):
            if is_blank(s.url):
                out.append(f"feed.sources[{i}].url")
            if is_blank(s.name):
                out.append(f"feed.sources[{i}].name")
        if is_blank(self.provider.model):
            out.append("provider.model")
        if is_blank(self.output.github.repo):
            out.append("output.github.repo")
        for i, a in enumerate(self.output.github.assignees):
            if is_blank(a):
                out.append(f"output.github.assignees[{i}]")
        for i, r in enumerate(self.review.reviewers):
            if is_blank(r):
                out.append(f"review.reviewers[{i}]")
        return out

    def api_key(self, env: Mapping[str, str]) -> str:
        """The key the provider needs, or an empty string for `fake`."""
        if self.provider.kind == "fake":
            return ""
        name = self.provider.api_key_env
        if not name:
            raise ConfigError("provider.api_key_env is empty")
        value = env.get(name, "")
        if not value:
            raise ConfigError(f"environment variable {name} (provider.api_key_env) is not set")
        return value

    def github_repo(self, env: Mapping[str, str]) -> str:
        """The repo issues open in; empty disables issues."""
        repo = env.get("OPINION_GALLERY_GITHUB_REPO") or self.output.github.repo
        return "" if is_blank(repo) else repo


def _section(raw: Mapping[str, Any], key: str) -> Mapping[str, Any]:
    value = raw.get(key)
    if value is None:
        raise ConfigError(f"config.yml is missing the `{key}:` section")
    if not isinstance(value, Mapping):
        raise ConfigError(f"config.yml `{key}:` must be a mapping")
    return value


def _str_list(value: Any, where: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise ConfigError(f"{where} must be a list of strings")
    return list(value)


def parse_config(raw: Mapping[str, Any]) -> Config:
    if not isinstance(raw, Mapping):
        raise ConfigError("config.yml must be a mapping at the top level")
    warnings = [f"unknown key `{k}` ignored" for k in raw if k not in KNOWN_TOP_LEVEL]

    org = _section(raw, "org")
    feed_raw = _section(raw, "feed")
    sources: list[FeedSource] = []
    for i, s in enumerate(feed_raw.get("sources") or []):
        if isinstance(s, str):
            sources.append(FeedSource(url=s))
        elif isinstance(s, Mapping) and isinstance(s.get("url"), str):
            sources.append(FeedSource(url=s["url"], name=str(s.get("name", ""))))
        else:
            raise ConfigError(f"feed.sources[{i}] needs a `url`")
    if not sources:
        raise ConfigError("feed.sources is empty")
    sections = _str_list(feed_raw.get("sections"), "feed.sections")
    if not sections:
        raise ConfigError("feed.sections is empty")
    feed = FeedConfig(
        sources=sources,
        sections=sections,
        lookback_hours=int(feed_raw.get("lookback_hours", 36)),
        max_stories=int(feed_raw.get("max_stories", 40)),
        skip_seen_days=int(feed_raw.get("skip_seen_days", 3)),
        summary_chars=int(feed_raw.get("summary_chars", 600)),
    )

    p = _section(raw, "provider")
    provider = ProviderConfig(
        kind=str(p.get("kind", "openai")),
        base_url=str(p.get("base_url", "") or ""),
        model=str(p.get("model", "") or ""),
        api_key_env=str(p.get("api_key_env", "") or ""),
        json_mode=bool(p.get("json_mode", False)),
        timeout_s=int(p.get("timeout_s", 120)),
    )
    if isinstance(p.get("max_tokens"), Mapping):
        provider.max_tokens.update({k: int(v) for k, v in p["max_tokens"].items()})
    if provider.kind not in PROVIDER_KINDS:
        raise ConfigError(f"provider.kind must be one of {sorted(PROVIDER_KINDS)}, not `{provider.kind}`")

    pe = _section(raw, "personas")
    personas = PersonasConfig(
        enabled=_str_list(pe.get("enabled"), "personas.enabled"),
        draft_threshold=int(pe.get("draft_threshold", 4)),
        max_drafts_per_persona=int(pe.get("max_drafts_per_persona", 2)),
    )
    if not personas.enabled:
        raise ConfigError("personas.enabled is empty")

    d = raw.get("debate") or {}
    debate = DebateConfig(
        enabled=bool(d.get("enabled", True)),
        max_participants=int(d.get("max_participants", 3)),
        outcome=str(d.get("outcome", "auto")),
        max_words_per_reply=int(d.get("max_words_per_reply", 250)),
    )
    if debate.outcome not in DEBATE_OUTCOMES:
        raise ConfigError(f"debate.outcome must be one of {sorted(DEBATE_OUTCOMES)}")
    if "rounds" in d and int(d["rounds"]) != 1:
        raise ConfigError("debate.rounds is fixed at 1")

    o = _section(raw, "output")
    gh = o.get("github") or {}
    output = OutputConfig(
        drafts_dir=str(o.get("drafts_dir", "opinion-gallery/drafts")),
        disclosure=str(o.get("disclosure", "")),
        github=GithubConfig(
            repo=str(gh.get("repo", "") or ""),
            labels=_str_list(gh.get("labels"), "output.github.labels"),
            assignees=_str_list(gh.get("assignees"), "output.github.assignees"),
        ),
    )
    if not output.disclosure:
        raise ConfigError("output.disclosure is empty")

    review = ReviewConfig(reviewers=_str_list((raw.get("review") or {}).get("reviewers"), "review.reviewers"))
    g = raw.get("guardrails") or {}
    guardrails = GuardrailsConfig(file=str(g.get("file", "guardrails.md")), modified=bool(g.get("modified", False)))
    r = raw.get("run") or {}
    run = RunConfig(state_file=str(r.get("state_file", "opinion-gallery/.state.json")), timezone=str(r.get("timezone", "UTC")))

    return Config(
        org_name=str(org.get("name", "")),
        org_site=str(org.get("site", "")),
        feed=feed,
        provider=provider,
        personas=personas,
        debate=debate,
        output=output,
        review=review,
        guardrails=guardrails,
        run=run,
        warnings=warnings,
    )


def load_config(path: Path) -> Config:
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ConfigError(f"{path} not found") from None
    except yaml.YAMLError as e:
        raise ConfigError(f"{path} is not valid YAML: {e}") from None
    return parse_config(raw or {})
