import pytest
from conftest import STARTER, write_contract

from opinion_gallery.config import ConfigError, parse_config
from opinion_gallery.contract import ContractError, load_contract, shipped_guardrails


def test_starter_contract_loads_and_reports_its_blanks():
    c = load_contract(STARTER)
    assert set(c.personas) == {"operator", "skeptic", "builder", "advocate", "strategist"}
    assert c.guardrails_match_shipped
    assert "feed.sources[0].url" in c.config.blanks()
    assert "review.reviewers[0]" in c.config.blanks()
    assert len(c.persona_blanks()) == 5


def test_starter_guardrails_is_the_shipped_copy():
    assert (STARTER / "guardrails.md").read_text() == shipped_guardrails()


def test_filled_contract(contract):
    assert [p.name for p in contract.enabled_personas()] == ["skeptic", "strategist", "operator"]
    assert contract.persona_blanks() == [] and contract.config.blanks() == []
    skeptic = contract.personas["skeptic"]
    assert skeptic.weight("SCIENCE") == 3 and skeptic.weight("LOCAL") == 0 and skeptic.threshold(4) == 4


def test_knowledge_files_are_read(tmp_path):
    c = write_contract(tmp_path)
    k = c / "personas" / "skeptic" / "knowledge"
    k.mkdir()
    (k / "b.md").write_text("second")
    (k / "a.md").write_text("first")
    assert load_contract(c).personas["skeptic"].knowledge == "first\n\nsecond"


def test_persona_name_must_match_directory(tmp_path):
    c = write_contract(tmp_path)
    f = c / "personas" / "skeptic" / "persona.md"
    f.write_text(f.read_text().replace("name: skeptic", "name: sceptic", 1))
    with pytest.raises(ContractError, match="must equal the directory name"):
        load_contract(c)


def test_persona_section_must_be_declared(tmp_path):
    c = write_contract(tmp_path)
    f = c / "personas" / "skeptic" / "persona.md"
    f.write_text(f.read_text().replace("SCIENCE: 3", "SCIENCE: 3\n  MARKETS: 2", 1))
    with pytest.raises(ContractError, match="MARKETS"):
        load_contract(c)


def test_enabled_persona_must_exist(tmp_path):
    c = write_contract(tmp_path, overrides={"personas": {"enabled": ["skeptic", "ghost"]}})
    with pytest.raises(ContractError, match="ghost"):
        load_contract(c)


def test_edited_guardrails_are_detected(tmp_path):
    c = write_contract(tmp_path)
    (c / "guardrails.md").write_text("# Guardrails\n\nMy own.\n")
    assert load_contract(c).guardrails_match_shipped is False


def _raw():
    import yaml

    return yaml.safe_load((STARTER / "config.yml").read_text())


def test_unknown_top_level_key_warns_and_rounds_is_fixed():
    raw = _raw()
    raw["extra"] = 1
    assert parse_config(raw).warnings == ["unknown key `extra` ignored"]
    raw["debate"]["rounds"] = 2
    with pytest.raises(ConfigError, match="rounds"):
        parse_config(raw)


def test_api_key_resolution():
    cfg = parse_config(_raw())
    with pytest.raises(ConfigError, match="OPENAI_API_KEY"):
        cfg.api_key({})
    assert cfg.api_key({"OPENAI_API_KEY": "k"}) == "k"
    cfg.provider.kind = "fake"
    assert cfg.api_key({}) == ""


def test_github_repo_env_override_and_blank():
    cfg = parse_config(_raw())
    assert cfg.github_repo({}) == ""  # the template blank disables issues
    assert cfg.github_repo({"OPINION_GALLERY_GITHUB_REPO": "o/r"}) == "o/r"


def test_bad_provider_kind():
    raw = _raw()
    raw["provider"]["kind"] = "gemini"
    with pytest.raises(ConfigError, match="provider.kind"):
        parse_config(raw)


def test_emergentlabs_example_is_filled_except_the_private_values():
    c = load_contract(STARTER.parent / "emergentlabs")
    assert [p.name for p in c.enabled_personas()] == ["operator", "skeptic", "builder", "strategist"]
    assert c.persona_blanks() == []
    assert c.guardrails_match_shipped
    assert sorted(c.config.blanks()) == ["feed.sources[0].name", "feed.sources[0].url", "output.github.repo", "review.reviewers[0]"]
    assert {p.display_name for p in c.enabled_personas()} == {"Monday", "Evidence First", "In the Open", "Long View"}
    assert all(p.weight("LOCAL") == 0 for p in c.enabled_personas())


def test_empty_api_key_env_means_no_key_from_this_contract():
    cfg = parse_config(_raw())
    cfg.provider.api_key_env = ""
    assert cfg.api_key({}) == ""  # the SDK or a local endpoint takes it from here
    cfg.provider.api_key_env = "NAMED_BUT_UNSET"
    with pytest.raises(ConfigError, match="NAMED_BUT_UNSET"):
        cfg.api_key({})
