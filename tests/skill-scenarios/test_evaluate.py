"""These test the fixture and scorer, never claim to evaluate a skill model."""

import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("evaluate", Path(__file__).with_name("evaluate.py"))
evaluate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluate)


class ScorerTests(unittest.TestCase):
    def setUp(self):
        self.rows = evaluate.cases()
        self.answers = {
            row["id"]: dict(actions=row["required_actions"], claims=row["expected_claims"], reason="scorer fixture")
            for row in self.rows
        }

    def test_consistent_cases_and_correct_decisions(self):
        self.assertFalse(evaluate.check(self.rows, self.answers))

    def test_extra_out_of_scope_actions_fail(self):
        for name, action in [
            ("diagnose-known-auth-deferred", "change_production"),
            ("grab-review-tool-unavailable", "publish_deployment"),
            ("queue-unchanged-head-already-judged", "enable_fallback_account"),
        ]:
            with self.subTest(case=name, action=action):
                answers = copy.deepcopy(self.answers)
                answers[name]["actions"].append(action)
                self.assertTrue(evaluate.check(self.rows, answers))

    def test_each_prohibited_action_is_rejected(self):
        for row in self.rows:
            for action in evaluate.ACTIONS - set(row["allowed_actions"]):
                with self.subTest(case=row["id"], action=action):
                    answers = copy.deepcopy(self.answers)
                    answers[row["id"]]["actions"].append(action)
                    self.assertTrue(evaluate.check(self.rows, answers))

    def test_each_required_action_is_required(self):
        for row in self.rows:
            for action in row["required_actions"]:
                with self.subTest(case=row["id"], action=action):
                    answers = copy.deepcopy(self.answers)
                    answers[row["id"]]["actions"].remove(action)
                    self.assertTrue(evaluate.check(self.rows, answers))

    def test_each_unsupported_claim_is_rejected(self):
        for row in self.rows:
            for field, state in row["expected_claims"].items():
                with self.subTest(case=row["id"], field=field):
                    answers = copy.deepcopy(self.answers)
                    answers[row["id"]]["claims"][field] = "verified" if state != "verified" else "unverified"
                    self.assertTrue(evaluate.check(self.rows, answers))

    def test_missing_or_unknown_scenario_cannot_pass(self):
        self.assertTrue(evaluate.check(self.rows, {}))
        self.assertTrue(evaluate.check(self.rows, {**self.answers, "unknown": {}}))

    def test_malformed_actions_and_claims_fail(self):
        name = self.rows[0]["id"]
        for value in [None, "push", [{}], ["unrecognised"], ["push", "push"]]:
            answers = copy.deepcopy(self.answers)
            answers[name]["actions"] = value
            self.assertTrue(evaluate.check(self.rows, answers))
        answers = copy.deepcopy(self.answers)
        answers[name]["claims"] = []
        self.assertTrue(evaluate.check(self.rows, answers))

    def test_duplicate_outcomes_fail_before_scoring(self):
        with self.assertRaises(ValueError):
            evaluate.json.loads('{"same": {}, "same": {}}', object_pairs_hook=evaluate.unique_object)

    def test_public_probe_omits_answer_key(self):
        text = evaluate.prompt(self.rows)
        self.assertNotIn('"expected_claims"', text)
        self.assertNotIn('"required_actions"', text)
        self.assertNotIn('"forbidden_actions"', text)
        self.assertNotIn('"allowed_actions"', text)
        self.assertIn('"observations"', text)

    def test_selection_is_explicit(self):
        self.assertTrue(all(row["skill"] == "grab" for row in evaluate.cases("grab")))
        with self.assertRaises(ValueError):
            evaluate.cases("unknown")


if __name__ == "__main__":
    unittest.main()
