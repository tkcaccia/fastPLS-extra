import unittest

from run_at_queue_boundary import alive, children_from_listing, matches_r_dispatcher


class QueueBoundaryTest(unittest.TestCase):
    def test_r_dispatcher_requires_exact_script_and_arguments(self):
        expected = ["Rscript", "/source/worker.R", "/output/path"]
        self.assertTrue(matches_r_dispatcher(
            "/R/bin/exec/R --no-echo --no-restore --file=/source/worker.R --args /output/path", expected))
        self.assertFalse(matches_r_dispatcher(
            "/R/bin/exec/R --file=/source/other.R --args /output/path", expected))
        self.assertFalse(matches_r_dispatcher(
            "/R/bin/exec/R --file=/source/worker.R --args /other/path", expected))
        self.assertFalse(matches_r_dispatcher(
            "python /source/worker.R /output/path", expected))

    def test_live_children_are_detected_without_status_files(self):
        listing = "12 4 S\n13 4 R\n14 4 Z\n15 8 S\n"
        self.assertEqual(children_from_listing(listing, 4), [12, 13])

    def test_only_absent_or_zombie_process_is_terminal(self):
        self.assertFalse(alive(None))
        self.assertFalse(alive(("Z+", "worker")))
        self.assertTrue(alive(("Ts", "queue")))
        self.assertTrue(alive(("S", "worker")))


if __name__ == "__main__":
    unittest.main()
