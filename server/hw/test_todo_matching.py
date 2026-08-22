import unittest

from todo_matching import normalize_todo_text, select_todo_candidate


class TodoMatchingTests(unittest.TestCase):
    def setUp(self):
        self.todos = [
            {"id": 1, "content": "수학 과제 제출"},
            {"id": 2, "content": "영어 단어 암기"},
            {"id": 3, "content": "영어 과제 제출"},
        ]

    def test_normalizes_case_and_whitespace(self):
        self.assertEqual(normalize_todo_text("  ABC   Def "), "abc def")

    def test_exact_match_wins_over_other_contains(self):
        row, reason = select_todo_candidate(self.todos, "영어 단어 암기")
        self.assertEqual(reason, "matched")
        self.assertEqual(row["id"], 2)

    def test_unique_contained_match(self):
        row, reason = select_todo_candidate(self.todos, "단어 암기")
        self.assertEqual(reason, "matched")
        self.assertEqual(row["id"], 2)

    def test_ambiguous_match_is_not_selected(self):
        row, reason = select_todo_candidate(self.todos, "과제 제출")
        self.assertEqual(reason, "ambiguous")
        self.assertIsNone(row)

    def test_duplicate_exact_match_is_not_selected(self):
        todos = [
            {"id": 1, "content": "보고서 제출"},
            {"id": 2, "content": "보고서 제출"},
        ]
        row, reason = select_todo_candidate(todos, "보고서 제출")
        self.assertEqual(reason, "ambiguous")
        self.assertIsNone(row)

    def test_missing_match_is_not_selected(self):
        row, reason = select_todo_candidate(self.todos, "운동하기")
        self.assertEqual(reason, "not_found")
        self.assertIsNone(row)

    def test_empty_hint_is_not_selected(self):
        row, reason = select_todo_candidate(self.todos, "  ")
        self.assertEqual(reason, "not_found")
        self.assertIsNone(row)


if __name__ == "__main__":
    unittest.main()
