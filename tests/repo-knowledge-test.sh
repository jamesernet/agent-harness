#!/usr/bin/env bash
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT="$SRC/skills/repo-knowledge/assets/validation"

# Prefer the pinned dependency in an existing environment, otherwise let uv
# create an isolated one. CI installs uv; no global Python install is changed.
if python3 -c 'import yaml; assert yaml.__version__ == "6.0.3"' >/dev/null 2>&1; then
  PYTHON=(python3)
elif command -v uv >/dev/null 2>&1; then
  PYTHON=(uv run --no-project --with-requirements "$KIT/requirements.txt" python3)
else
  echo "repo-knowledge tests: skipped (need uv or Python with pinned PyYAML)"
  exit 0
fi

"${PYTHON[@]}" - "$KIT" <<'PYTEST'
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

SOURCE_KIT = Path(sys.argv.pop()).resolve()
META = {
    "type": "Concept", "title": "Request", "description": "A synthetic request definition.",
    "tags": ["request"], "generated": {"by": "process:fixture", "at": "2026-11-20T12:00:00Z"},
    "status": "draft", "sources": [{"id": "contract", "resource": "https://example.com/contract"}],
}
BODY = "# Request\n\nA request records intent.[^contract]\n\n[^contract]: Synthetic request contract.\n"


class KnowledgeChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="repo-knowledge-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.kit = self.root / "detached-kit"
        shutil.copytree(SOURCE_KIT, self.kit)
        self.bundle = self.root / "bundle"
        (self.bundle / "terms").mkdir(parents=True)
        (self.bundle / "index.md").write_text('---\nokf_version: "0.3"\n---\n# Library\n\n- [Terms](terms/): Working definitions.\n')
        (self.bundle / "terms/index.md").write_text('# Terms\n\n- [Request](request.md): A synthetic request.\n')
        self.concept = self.bundle / "terms/request.md"
        self.write()

    def write(self, meta=None, body=BODY, path=None):
        (path or self.concept).write_text("---\n" + yaml.safe_dump(meta if meta is not None else META, sort_keys=False) + "---\n\n" + body)

    def run_check(self, expected=0):
        env = dict(os.environ)
        env.pop("PYTHONPATH", None)
        result = subprocess.run([sys.executable, str(self.kit / "check.py"), str(self.bundle), "--json", "--now", "2026-11-20T12:00:00Z"], cwd=self.root, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def codes(self, expected=1):
        return {finding["code"] for finding in self.run_check(expected)["findings"]}

    def test_detached_kit_passes_and_preserves_upstream_identity(self):
        report = self.run_check()
        self.assertEqual(report["upstream_commit"], "527e81aff55992be21507e97004286789126f88c")
        self.assertEqual(report["files_checked"], 3)
        self.assertEqual(report["errors"], 0)
        self.assertFalse(list(self.kit.rglob("__pycache__")))

    def test_required_profile_fields_fail_independently(self):
        for field, code in [("title", "R003"), ("description", "R003"), ("tags", "R004"), ("generated", "R005"), ("status", "R006"), ("sources", "R007")]:
            with self.subTest(field=field):
                meta = copy.deepcopy(META)
                del meta[field]
                self.write(meta)
                self.assertIn(code, self.codes())

    def test_source_free_gap_requires_all_explicit_structure(self):
        meta = copy.deepcopy(META)
        del meta["sources"]
        meta["x-repo-knowledge-gap"] = True
        body = "# Unknown process\n\n## Questions\n\n- Who confirms the process?\n\n## Evidence needed\n\n- An owner interview.\n"
        self.write(meta, body)
        self.run_check()
        for mutation in ("status", "marker", "heading"):
            candidate = copy.deepcopy(meta)
            text = body
            if mutation == "status":
                candidate["status"] = "stable"
            elif mutation == "marker":
                candidate["x-repo-knowledge-gap"] = False
            else:
                text = body.replace("## Evidence needed", "## Notes")
            self.write(candidate, text)
            self.assertIn("R007", self.codes())

    def test_generated_requires_timestamp_not_only_actor(self):
        meta = copy.deepcopy(META)
        del meta["generated"]["at"]
        self.write(meta)
        self.assertIn("R005", self.codes())

    def test_concept_link_does_not_hide_orphan_from_indexes(self):
        orphan = self.bundle / "terms/orphan.md"
        self.write(path=orphan)
        self.write(body=BODY + "\nSee [another request](orphan.md).\n")
        self.assertIn("R008", self.codes())

    def test_root_link_does_not_replace_immediate_parent_listing(self):
        (self.bundle / "terms/index.md").write_text("# Terms\n")
        with (self.bundle / "index.md").open("a") as stream:
            stream.write("\n- [Request](terms/request.md): Direct root link.\n")
        self.assertIn("R013", self.codes())

    def test_nested_index_needs_immediate_parent_listing(self):
        (self.bundle / "terms/deeper").mkdir()
        (self.bundle / "terms/deeper/index.md").write_text("# Deeper terms\n")
        with (self.bundle / "index.md").open("a") as stream:
            stream.write("\n- [Deeper](terms/deeper/index.md): Direct root link.\n")
        self.assertIn("R013", self.codes())

    def test_all_nested_indexes_are_checked(self):
        with (self.bundle / "terms/index.md").open("a") as stream:
            stream.write("\n- [Missing](missing.md): Not written.\n")
        self.assertIn("R009", self.codes())

    def test_index_directory_requires_its_own_index(self):
        (self.bundle / "empty").mkdir()
        with (self.bundle / "index.md").open("a") as stream:
            stream.write("\n- [Empty](empty/): Missing catalogue.\n")
        self.assertIn("R009", self.codes())

    def test_nested_index_frontmatter_is_rejected_by_upstream(self):
        path = self.bundle / "terms/index.md"
        path.write_text("---\ntype: Index\n---\n" + path.read_text())
        self.assertIn("E004", self.codes())

    def test_citation_needs_renderable_definition(self):
        self.write(body="# Request\n\nA request records intent.[^contract]\n")
        self.assertIn("R012", self.codes())

    def test_definition_must_match_source_and_be_unique(self):
        self.write(body=BODY + "\n[^unknown]: Unlisted evidence.\n")
        self.assertIn("R011", self.codes())
        self.write(body=BODY + "\n[^contract]: A second definition.\n")
        self.assertIn("R010", self.codes())

    def test_upstream_strict_rejects_invalid_actors_and_duplicate_yaml(self):
        meta = copy.deepcopy(META)
        meta["generated"]["by"] = "unknown actor"
        self.write(meta)
        self.assertIn("W103", self.codes())
        self.concept.write_text(self.concept.read_text().replace("type: Concept\n", "type: Concept\ntype: Reference\n"))
        self.assertIn("E007", self.codes())

    def test_staleness_is_information_without_failure(self):
        meta = copy.deepcopy(META)
        meta["stale_after"] = "2026-11-01"
        self.write(meta)
        report = self.run_check()
        self.assertIn("I201", {item["code"] for item in report["findings"]})
        self.assertEqual(report["warnings"], 0)

    def test_root_version_matches_the_pinned_validator(self):
        path = self.bundle / "index.md"
        path.write_text(path.read_text().replace('"0.3"', '"0.2"'))
        self.assertIn("R002", self.codes())

    def test_case_collisions_fail_on_case_sensitive_filesystems(self):
        other = self.bundle / "terms/Request.md"
        self.write(path=other)
        if len(list((self.bundle / "terms").glob("*equest.md"))) < 2:
            self.skipTest("fixture filesystem does not support case-distinct paths")
        self.assertIn("R001", self.codes())

    def test_now_requires_datetime_as_documented(self):
        result = subprocess.run([sys.executable, str(self.kit / "check.py"), str(self.bundle), "--now", "2026-11-20"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("date-time", result.stderr)

    def test_tampered_upstream_never_executes(self):
        path = self.kit / "upstream/validate.py"
        path.write_text("raise RuntimeError('should not execute')\n")
        result = subprocess.run([sys.executable, str(self.kit / "check.py"), str(self.bundle)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertNotIn("RuntimeError", result.stderr)


unittest.main()
PYTEST
