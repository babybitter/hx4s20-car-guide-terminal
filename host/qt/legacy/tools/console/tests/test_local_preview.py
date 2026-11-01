import hashlib
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PIL import Image
from local_preview import DEFAULT_FOLDER, DEFAULT_MANIFEST, LocalPreview


class PreviewFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name) / "images"
        self.folder.mkdir()
        self.manifest = Path(self.temp.name) / "catalog_manifest.json"
        self.records = []
        for page, color in ((1, (220, 30, 10)), (2, (10, 90, 220))):
            output = io.BytesIO()
            Image.new("RGB", (640, 480), color).save(output, format="BMP")
            data = output.getvalue()
            offset = struct.unpack_from("<I", data, 10)[0]
            (self.folder / f"{page:03d}.BMP").write_bytes(data)
            self.records.append(dict(source_id=page-1, filename=f"{page:03d}.BMP",
                title=("线路总览" if page == 1 else "湖畔步道"), width=640, height=480,
                bpp=24, pixel_offset=offset, file_size=len(data),
                pixel_crc32=f"{zlib.crc32(data[offset:]) & 0xffffffff:08X}",
                file_sha256=hashlib.sha256(data).hexdigest(), source="must-not-be-used.bmp"))
        self.write_manifest()
        self.loader = LocalPreview(self.folder, self.manifest)

    def write_manifest(self):
        self.manifest.write_text(json.dumps(dict(schema=1,
            crc_scope="BGR pixel bytes, reflected IEEE CRC32", assets=self.records)), encoding="utf-8")

    def status(self, page=1, count=2, ready=True):
        return SimpleNamespace(page=page, count=count, ready=ready)


class LocalPreviewTests(PreviewFixture, unittest.TestCase):
    def test_verified_bmp_thumbnail_title_and_metadata_read_only(self):
        before = {p: p.read_bytes() for p in (self.manifest, *self.folder.iterdir())}
        result = self.loader.load(self.status())
        self.assertEqual(result.image.size, (320, 240))
        self.assertEqual(result.image.getpixel((100, 100)), (220, 30, 10))
        self.assertEqual(result.title, "001 · 线路总览")
        self.assertIn(self.records[0]["file_sha256"], result.metadata)
        self.assertIn(self.records[0]["pixel_crc32"], result.metadata)
        self.assertIn("最近有效Q", result.metadata)
        self.assertIn("不代表板端", result.message)
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_sha_mismatch_never_shows_old_or_source_image(self):
        self.assertIsNotNone(self.loader.load(self.status()).image)
        path = self.folder / "001.BMP"
        data = bytearray(path.read_bytes())
        data[-1] ^= 1
        path.write_bytes(data)
        result = self.loader.load(self.status())
        self.assertIsNone(result.image)
        self.assertIn("SHA256不匹配", result.message)
        self.assertIn(hashlib.sha256(data).hexdigest(), result.metadata)
        self.assertIn(self.records[0]["file_sha256"], result.metadata)

    def test_crc_mismatch_and_format_mismatch(self):
        self.records[0]["pixel_crc32"] = "00000000"
        self.write_manifest()
        result = self.loader.load(self.status())
        self.assertIsNone(result.image)
        self.assertIn("CRC32不匹配", result.message)
        self.records[0]["width"] = 639
        self.write_manifest()
        self.assertIn("尺寸/格式/长度", self.loader.load(self.status()).message)

    def test_missing_and_unlisted_page_clear(self):
        (self.folder / "001.BMP").unlink()
        result = self.loader.load(self.status())
        self.assertIsNone(result.image)
        self.assertIn("缺少本地文件 001.BMP", result.message)
        result = self.loader.load(self.status(page=128, count=128))
        self.assertIsNone(result.image)
        self.assertIn("未收录", result.message)

    def test_unverified_not_ready_and_invalid_ranges(self):
        for state in (None, self.status(ready=False), self.status(count=0),
                      self.status(page=3), self.status(page=0), self.status(count=129)):
            with self.subTest(state=state):
                result = self.loader.load(state)
                self.assertIsNone(result.image)
                self.assertTrue(result.message)

    def test_manifest_errors_and_no_path_escape(self):
        for key, value in (("filename", "../outside.BMP"), ("file_sha256", 123),
                           ("pixel_crc32", "invalid"), ("title", None)):
            with self.subTest(key=key):
                original = self.records[0][key]
                self.records[0][key] = value
                self.write_manifest()
                self.assertIsNone(self.loader.load(self.status()).image)
                self.records[0][key] = original
        self.manifest.write_text("{invalid", encoding="utf-8")
        self.assertIn("不可用", self.loader.load(self.status()).message)
        self.manifest.unlink()
        self.assertIsNone(self.loader.load(self.status()).image)

    def test_chosen_folder_does_not_change_manifest(self):
        chosen = Path(self.temp.name) / "other"
        chosen.mkdir()
        (chosen / "catalog_manifest.json").write_text("{}", encoding="utf-8")
        (chosen / "001.BMP").write_bytes((self.folder / "002.BMP").read_bytes())
        self.loader.folder = chosen
        result = self.loader.load(self.status())
        self.assertIsNone(result.image)
        self.assertIn("SHA256不匹配", result.message)
        self.assertEqual(self.loader.manifest_path, self.manifest)

    def test_default_project_catalog_eight_approved_files(self):
        self.assertTrue(DEFAULT_MANIFEST.is_file())
        self.assertEqual(DEFAULT_FOLDER.name, "catalog")
        for page in range(1, 9):
            result = LocalPreview().load(self.status(page=page, count=8))
            self.assertIsNotNone(result.image, result.message)
            self.assertEqual(result.image.size, (320, 240))


if __name__ == "__main__":
    unittest.main(verbosity=2)
