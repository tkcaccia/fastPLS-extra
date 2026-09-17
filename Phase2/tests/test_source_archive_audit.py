import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "archive_audit", Path(__file__).resolve().parents[1] / "tools/audit_source_archive.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ArchiveAuditTests(unittest.TestCase):
    def archive(self, folder, entries):
        path = Path(folder) / "source.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name, value in entries:
                item = tarfile.TarInfo(name)
                if value is None:
                    item.type = tarfile.SYMTYPE
                    item.linkname = "/outside"
                    archive.addfile(item)
                else:
                    item.size = len(value)
                    archive.addfile(item, io.BytesIO(value))
        return path

    def test_records_real_packaged_assets(self):
        with tempfile.TemporaryDirectory() as folder:
            path = self.archive(folder, [
                ("fastPLS/DESCRIPTION", b"License: MIT"),
                ("fastPLS/data/colon.rda", b"example"),
                ("fastPLS/src/irlba.c", b"solver"),
                ("fastPLS/src/old.o", b"object"),
            ])
            result = module.audit(path)
            self.assertEqual(result["dataset_files"], ["data/colon.rda"])
            self.assertEqual(result["bundled_irlba_sources"], ["src/irlba.c"])
            self.assertEqual(result["compiled_artifacts"], ["src/old.o"])
            self.assertFalse(result["mit_release_ready"])

    def test_rejects_links_and_unsafe_names(self):
        for name, data in [("fastPLS/link", None), ("/fastPLS/a", b""),
                           ("fastPLS/../a", b"")]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                with self.assertRaises(ValueError):
                    module.audit(self.archive(folder, [(name, data)]))

    def test_rejects_duplicate_entries(self):
        with tempfile.TemporaryDirectory() as folder:
            path = self.archive(folder, [("fastPLS/DESCRIPTION", b"x")] * 2)
            with self.assertRaisesRegex(ValueError, "Duplicate"):
                module.audit(path)


if __name__ == "__main__":
    unittest.main()
