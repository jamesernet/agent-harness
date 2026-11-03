import json

import pytest
from conftest import FIXTURES, STARTER, write_contract

from opinion_gallery import cli


def test_check_on_unfilled_starter_exits_2(capsys):
    with pytest.raises(SystemExit) as e:
        raise SystemExit(cli.main(["check", "--contract", str(STARTER)]))
    assert e.value.code == 2
    out = capsys.readouterr().out
    assert "blank: feed.sources[0].url" in out and "not ready to run" in out


def test_check_on_filled_contract_exits_0(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(cli.shutil, "which", lambda name: "/usr/bin/gh")
    c = write_contract(tmp_path)
    assert cli.main(["check", "--contract", str(c)]) == 0
    assert "ready" in capsys.readouterr().out


def test_check_reports_missing_gh(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(cli.shutil, "which", lambda name: None)
    assert cli.main(["check", "--contract", str(write_contract(tmp_path))]) == 2
    assert "`gh` is not on PATH" in capsys.readouterr().out


def test_run_report_only_with_fake_provider(tmp_path, capsys, monkeypatch):
    import opinion_gallery.run as run_mod
    from conftest import file_fetch

    monkeypatch.setattr(run_mod.feeds, "http_fetch", file_fetch)
    c = write_contract(tmp_path)
    code = cli.main(["run", "--contract", str(c), "--report-only", "--date", "2026-11-03", "--fake-replies", str(FIXTURES / "fake_replies.json")])
    out = capsys.readouterr().out
    assert code == 0 and "(report only)" in out and "Pieces: 3" in out
    assert not (tmp_path / "drafts").exists()


def test_run_refuses_unfilled_contract(capsys):
    assert cli.main(["run", "--contract", str(STARTER), "--report-only"]) == 2
    assert "problem:" in capsys.readouterr().err


def test_bench_against_fixture_stories(tmp_path, capsys):
    c = write_contract(tmp_path)
    code = cli.main(["bench", "--contract", str(c), "--persona", "skeptic", "--stories", str(FIXTURES / "stories.json"), "--fake-replies", str(FIXTURES / "fake_replies.json"), "--draft"])
    out = capsys.readouterr().out
    assert code == 0 and out.startswith("5  SCIENCE") and "# The claim, the evidence" in out


def test_bench_unknown_persona(tmp_path):
    with pytest.raises(SystemExit) as e:
        cli.main(["bench", "--contract", str(write_contract(tmp_path)), "--persona", "ghost"])
    assert e.value.code == 2


def test_bad_subcommand_exits_2():
    with pytest.raises(SystemExit) as e:
        cli.main(["nope"])
    assert e.value.code == 2


def test_missing_contract_dir_exits_2(tmp_path):
    with pytest.raises(SystemExit) as e:
        cli.main(["check", "--contract", str(tmp_path / "missing")])
    assert e.value.code == 2


def test_provider_override_lets_bench_run_offline(tmp_path, capsys):
    c = write_contract(tmp_path, overrides={"provider": {"kind": "openai", "model": "m", "api_key_env": "UNSET_KEY"}})
    code = cli.main(["bench", "--contract", str(c), "--persona", "operator", "--stories", str(FIXTURES / "stories.json"), "--fake-replies", str(FIXTURES / "fake_replies.json"), "--provider", "fake"])
    assert code == 0 and "4  BUSINESS" in capsys.readouterr().out


def test_dotenv_is_read_without_overriding(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("ALREADY", "kept")
    monkeypatch.delenv("FROM_DOTENV", raising=False)
    (tmp_path / ".env").write_text("# comment\nFROM_DOTENV=secret\nALREADY=overwritten\nEMPTY=\nQUOTED='q'\n")
    cli.load_dotenv()
    import os

    assert os.environ["FROM_DOTENV"] == "secret" and os.environ["ALREADY"] == "kept" and os.environ["QUOTED"] == "q"
    assert "EMPTY" not in os.environ


def test_check_names_the_credential_source_when_no_variable_is_given(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(cli.shutil, "which", lambda name: "/usr/bin/gh")
    c = write_contract(tmp_path, overrides={"provider": {"kind": "anthropic", "model": "claude-opus-5", "api_key_env": ""}})
    assert cli.main(["check", "--contract", str(c)]) == 0
    assert "ant auth login" in capsys.readouterr().out


def test_dotenv_ignores_lines_that_are_not_variables(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    for name in ("GOOD", "printf 'ANTHROPIC_API_KEY", "2BAD", "has space"):
        monkeypatch.delenv(name, raising=False)
    (tmp_path / ".env").write_text(
        "GOOD=yes\n"
        "# either: a key file, from the clipboard\n"
        "printf 'ANTHROPIC_API_KEY=%s\\n' \"$(pbpaste)\" > .env\n"
        "2BAD=no\n"
        "has space=no\n"
    )
    cli.load_dotenv()
    import os

    assert os.environ["GOOD"] == "yes"
    assert not any(k for k in os.environ if not cli.IDENTIFIER_RE.fullmatch(k))
