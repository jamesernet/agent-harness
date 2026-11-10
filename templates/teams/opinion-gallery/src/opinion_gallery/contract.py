"""A contract directory -> Contract: config, brief, guardrails, personas."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from importlib import resources
from pathlib import Path
from typing import Any

import yaml

from .config import Config, ConfigError, is_blank, load_config


class ContractError(ValueError):
    """A contract problem a person has to fix."""


@dataclass
class Persona:
    name: str
    display_name: str
    enabled: bool
    sections: dict[str, int]
    draft_threshold: int | None
    body: str
    knowledge: str = ""

    def weight(self, section: str) -> int:
        return int(self.sections.get(section, 0))

    def threshold(self, default: int) -> int:
        return default if self.draft_threshold is None else int(self.draft_threshold)


@dataclass
class Contract:
    path: Path
    config: Config
    shared: str
    guardrails: str
    guardrails_match_shipped: bool
    personas: dict[str, Persona] = field(default_factory=dict)

    @property
    def name(self) -> str:
        return self.path.name

    def enabled_personas(self) -> list[Persona]:
        return [self.personas[n] for n in self.config.personas.enabled if self.personas[n].enabled]

    def persona_blanks(self) -> list[str]:
        """Blanks left in persona display names, which end up in bylines."""
        return [f"personas/{p.name}: display_name" for p in self.personas.values() if is_blank(p.display_name)]


def split_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    if not text.startswith("---\n"):
        raise ContractError("persona.md must start with a `---` frontmatter block")
    parts = text.split("\n---\n", 1)
    if len(parts) != 2:
        raise ContractError("persona.md frontmatter is not terminated by `---`")
    try:
        meta = yaml.safe_load(parts[0][4:]) or {}
    except yaml.YAMLError as e:
        raise ContractError(f"persona.md frontmatter is not valid YAML: {e}") from None
    if not isinstance(meta, dict):
        raise ContractError("persona.md frontmatter must be a mapping")
    return meta, parts[1].lstrip("\n")


def shipped_guardrails() -> str:
    return resources.files("opinion_gallery").joinpath("guardrails.md").read_text(encoding="utf-8")


def _digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_persona(directory: Path, sections: list[str]) -> Persona:
    file = directory / "persona.md"
    if not file.is_file():
        raise ContractError(f"{file} not found")
    meta, body = split_frontmatter(file.read_text(encoding="utf-8"))
    name = str(meta.get("name", ""))
    if name != directory.name:
        raise ContractError(f"{file}: frontmatter name `{name}` must equal the directory name `{directory.name}`")
    raw_sections = meta.get("sections") or {}
    if not isinstance(raw_sections, dict):
        raise ContractError(f"{file}: `sections` must be a mapping")
    unknown = sorted(set(raw_sections) - set(sections))
    if unknown:
        raise ContractError(f"{file}: sections {unknown} are not in config.yml feed.sections")
    threshold = meta.get("draft_threshold")
    knowledge_dir = directory / "knowledge"
    knowledge = ""
    if knowledge_dir.is_dir():
        pieces = [p.read_text(encoding="utf-8") for p in sorted(knowledge_dir.glob("*.md"))]
        knowledge = "\n\n".join(pieces)
    return Persona(
        name=name,
        display_name=str(meta.get("display_name", name)),
        enabled=bool(meta.get("enabled", True)),
        sections={str(k): int(v) for k, v in raw_sections.items()},
        draft_threshold=None if threshold is None else int(threshold),
        body=body,
        knowledge=knowledge,
    )


def load_contract(path: Path) -> Contract:
    path = Path(path)
    if not path.is_dir():
        raise ContractError(f"{path} is not a directory")
    try:
        config = load_config(path / "config.yml")
    except ConfigError as e:
        raise ContractError(str(e)) from None
    shared_file = path / "shared.md"
    if not shared_file.is_file():
        raise ContractError(f"{shared_file} not found")
    guard_file = path / config.guardrails.file
    if not guard_file.is_file():
        raise ContractError(f"{guard_file} not found")
    guardrails = guard_file.read_text(encoding="utf-8")
    personas: dict[str, Persona] = {}
    personas_dir = path / "personas"
    for d in sorted(p for p in personas_dir.iterdir() if p.is_dir()) if personas_dir.is_dir() else []:
        personas[d.name] = load_persona(d, config.feed.sections)
    missing = [n for n in config.personas.enabled if n not in personas]
    if missing:
        raise ContractError(f"config.yml personas.enabled names {missing}, which have no personas/<name>/persona.md")
    return Contract(
        path=path,
        config=config,
        shared=shared_file.read_text(encoding="utf-8"),
        guardrails=guardrails,
        guardrails_match_shipped=_digest(guardrails) == _digest(shipped_guardrails()),
        personas=personas,
    )
