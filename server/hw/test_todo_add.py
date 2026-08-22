import unittest
from datetime import date, datetime, time

from app.todo_add import (
    normalize_content,
    parse_date,
    parse_deadline,
    resolve_category,
    resolve_notify,
)

TODAY = date(2026, 8, 14)


class NormalizeContentTests(unittest.TestCase):
    def test_collapses_whitespace(self):
        self.assertEqual(normalize_content("  영어   숙제 "), "영어 숙제")

    def test_empty_input(self):
        self.assertEqual(normalize_content(None), "")
        self.assertEqual(normalize_content("   "), "")

    def test_truncates_long_title(self):
        self.assertEqual(len(normalize_content("가" * 100)), 40)


class ParseDateTests(unittest.TestCase):
    def test_valid_date(self):
        self.assertEqual(parse_date("2026-08-15", TODAY), date(2026, 8, 15))

    def test_missing_or_invalid_falls_back_to_today(self):
        self.assertEqual(parse_date(None, TODAY), TODAY)
        self.assertEqual(parse_date("내일", TODAY), TODAY)
        self.assertEqual(parse_date("2026-13-40", TODAY), TODAY)


class ParseDeadlineTests(unittest.TestCase):
    def test_hhmm(self):
        self.assertEqual(parse_deadline("21:00"), time(21, 0))

    def test_hhmmss_drops_seconds(self):
        self.assertEqual(parse_deadline("21:00:30"), time(21, 0))

    def test_missing_or_invalid(self):
        self.assertIsNone(parse_deadline(None))
        self.assertIsNone(parse_deadline(""))
        self.assertIsNone(parse_deadline("오후 9시"))
        self.assertIsNone(parse_deadline("25:00"))


class ResolveCategoryTests(unittest.TestCase):
    def setUp(self):
        self.cats = [
            {"id": "c1", "name": "학업"},
            {"id": "c2", "name": "일정"},
            {"id": "c3", "name": "건강"},
        ]

    def test_exact_name(self):
        self.assertEqual(resolve_category(self.cats, "건강")["id"], "c3")

    def test_unique_contained_name(self):
        self.assertEqual(resolve_category(self.cats, "학업 과제")["id"], "c1")

    def test_unknown_name_without_etc_falls_back_to_first(self):
        self.assertEqual(resolve_category(self.cats, "기타")["id"], "c1")

    def test_etc_category_is_preferred_when_present(self):
        cats = self.cats + [{"id": "c4", "name": "기타"}]
        self.assertEqual(resolve_category(cats, "고양이 밥주기")["id"], "c4")

    def test_no_categories(self):
        self.assertIsNone(resolve_category([], "학업"))


class ResolveNotifyTests(unittest.TestCase):
    def test_no_deadline_means_no_notify(self):
        now = datetime(2026, 8, 14, 10, 0)
        self.assertEqual(resolve_notify(TODAY, None, None, now), (False, None))

    def test_deadline_defaults_to_one_hour_before(self):
        now = datetime(2026, 8, 14, 10, 0)
        self.assertEqual(resolve_notify(TODAY, time(21, 0), None, now), (True, 60))

    def test_explicit_thirty_minutes(self):
        now = datetime(2026, 8, 14, 10, 0)
        self.assertEqual(resolve_notify(TODAY, time(21, 0), 30, now), (True, 30))

    def test_odd_value_snaps_to_nearest_choice(self):
        now = datetime(2026, 8, 14, 10, 0)
        self.assertEqual(resolve_notify(TODAY, time(21, 0), 20, now), (True, 30))
        self.assertEqual(resolve_notify(TODAY, time(21, 0), 90, now), (True, 60))
        self.assertEqual(resolve_notify(TODAY, time(21, 0), "abc", now), (True, 60))

    def test_auto_downgrades_to_thirty_when_hour_mark_passed(self):
        now = datetime(2026, 8, 14, 20, 15)   # 마감 21:00 → 1시간 전은 지났고 30분 전은 남음
        self.assertEqual(resolve_notify(TODAY, time(21, 0), None, now), (True, 30))

    def test_notify_off_when_both_marks_passed(self):
        now = datetime(2026, 8, 14, 20, 50)
        self.assertEqual(resolve_notify(TODAY, time(21, 0), None, now), (False, None))

    def test_explicit_choice_is_not_downgraded(self):
        now = datetime(2026, 8, 14, 20, 15)
        self.assertEqual(resolve_notify(TODAY, time(21, 0), 60, now), (False, None))

    def test_future_date_is_always_notified(self):
        now = datetime(2026, 8, 14, 23, 50)
        self.assertEqual(
            resolve_notify(date(2026, 8, 15), time(0, 10), None, now), (True, 60)
        )

    def test_past_date_is_not_notified(self):
        now = datetime(2026, 8, 14, 10, 0)
        self.assertEqual(
            resolve_notify(date(2026, 8, 13), time(21, 0), None, now), (False, None)
        )


if __name__ == "__main__":
    unittest.main()
