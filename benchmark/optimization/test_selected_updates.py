import unittest

from plan_selected_updates import changes


class SelectedUpdateTest(unittest.TestCase):
    def test_only_changed_components_require_new_fits(self):
        current = {("x", "simpls"): 8, ("y", "plssvd"): 2}
        stored = {("x", "simpls"): 7, ("y", "plssvd"): 2}
        result = changes(current, stored)
        self.assertTrue(result[0]["requires_new_fit"])
        self.assertEqual(result[0]["matched_workload_ncomp"], 7)
        self.assertFalse(result[1]["requires_new_fit"])

    def test_missing_families_are_not_silently_dropped(self):
        with self.assertRaises(ValueError):
            changes({("x", "simpls"): 8}, {})


if __name__ == "__main__":
    unittest.main()
