"""Read-only, manifest-bound local BMP previews; never a board image capture."""
from dataclasses import dataclass
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import zlib

try:
    from PIL import Image
except ImportError:
    Image = None

PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FOLDER = PROJECT_ROOT / "tools/bmp/output_bmp/catalog"
DEFAULT_MANIFEST = PROJECT_ROOT / "assets/catalog_manifest.json"
PREVIEW_NOTICE = "本地素材预览，非HDMI采集；不证明板端画面"
THUMBNAIL_SIZE = (320, 240)


@dataclass
class PreviewResult:
    message: str
    title: str = "暂无本地图片"
    metadata: str = ""
    image: object = None
    page: int | None = None


class LocalPreview:
    def __init__(self, folder=DEFAULT_FOLDER, manifest_path=DEFAULT_MANIFEST):
        self.folder = Path(folder)
        # Folder selection never changes the approved project manifest.
        self.manifest_path = Path(manifest_path)

    def _entry(self, page):
        with self.manifest_path.open("rb") as stream:
            raw = stream.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            raise ValueError("项目素材清单过大")
        manifest = json.loads(raw.decode("utf-8-sig"))
        if not isinstance(manifest, dict) or manifest.get("schema") != 1:
            raise ValueError("项目素材清单版本无效")
        assets = manifest.get("assets")
        if not isinstance(assets, list):
            raise ValueError("项目素材清单缺少assets")
        entries = {}
        for entry in assets:
            if not isinstance(entry, dict):
                raise ValueError("项目素材清单条目无效")
            source = entry.get("source_id")
            if type(source) is not int or not 0 <= source < 128 or source in entries:
                raise ValueError("项目素材清单页号重复或越界")
            if entry.get("filename") != f"{source + 1:03d}.BMP":
                raise ValueError("项目素材清单文件名与页号不一致")
            entries[source] = entry
        scope = manifest.get("crc_scope")
        if scope != "BGR pixel bytes, reflected IEEE CRC32":
            raise ValueError("项目清单CRC范围不受支持")
        return entries.get(page - 1), scope

    def load(self, status):
        """Caller supplies only Session.receive()'s verified Q status.

        Re-read both manifest and image on each Q; a modified file must not
        keep an old verified thumbnail alive through an unchecked cache.
        """
        if status is None:
            return PreviewResult("等待有效Q状态；本地预览已清除")
        page, count = status.page, status.count
        if not status.ready:
            return PreviewResult("板端READY=0，尚未就绪；本地预览已清除")
        if type(page) is not int or type(count) is not int or not 1 <= page <= count <= 128:
            return PreviewResult("Q页号或数量越界（须1≤P≤C≤128）；本地预览已清除")
        result = PreviewResult("", page=page)
        try:
            entry, scope = self._entry(page)
            if entry is None:
                result.message = f"项目清单未收录第{page:03d}页；没有对应本地预览"
                return result
            title = entry.get("title")
            expected_sha = entry.get("file_sha256", "")
            expected_crc = entry.get("pixel_crc32", "")
            if not isinstance(title, str) or not title or not isinstance(expected_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha):
                raise ValueError("清单标题或文件SHA256无效")
            if not isinstance(expected_crc, str) or not re.fullmatch(r"[0-9a-fA-F]{8}", expected_crc):
                raise ValueError("清单像素CRC32无效")
            expected_sha, expected_crc = expected_sha.lower(), expected_crc.upper()
            result.title = f"{page:03d} · {title}"
            result.metadata = (f"最近有效Q：P={page:03d} C={count:03d} READY=1\n"
                               f"清单文件：{entry['filename']}\n"
                               f"清单像素CRC32：{expected_crc}\n"
                               f"CRC范围：{scope}\n清单SHA256：{expected_sha}")
            path = self.folder / entry["filename"]
            if not path.is_file():
                result.message = f"缺少本地文件 {entry['filename']}；已清除图片，不使用其他素材替代"
                return result
            with path.open("rb") as stream:
                data = stream.read(16 * 1024 * 1024 + 1)
            if len(data) > 16 * 1024 * 1024:
                raise ValueError("本地BMP超出预览大小限制")
            actual_sha = hashlib.sha256(data).hexdigest()
            result.metadata += f"\n实际SHA256：{actual_sha}"
            if actual_sha != expected_sha:
                result.message = "SHA256不匹配：本地文件与项目清单不同；已清除图片，不自动替换"
                return result
            if len(data) < 54 or data[:2] != b"BM":
                raise ValueError("文件不是有效BMP")
            dib, width, signed_height, planes, bpp, compression = struct.unpack_from("<IiiHHI", data, 14)
            offset = struct.unpack_from("<I", data, 10)[0]
            height = abs(signed_height)
            if dib < 40 or planes != 1 or bpp != 24 or compression != 0 or not 1 <= width <= 4096 or not 1 <= height <= 4096:
                raise ValueError("预览只支持有效24位未压缩BMP")
            actual = (width, height, bpp, offset, len(data))
            expected = tuple(entry.get(k) for k in ("width", "height", "bpp", "pixel_offset", "file_size"))
            if actual != expected:
                raise ValueError("BMP尺寸/格式/长度与项目清单不匹配")
            stride = (width * 3 + 3) & ~3
            if offset < 14 + dib or offset + stride * height > len(data):
                raise ValueError("BMP像素范围越界或文件截断")
            crc = 0
            for row in range(height):
                start = offset + row * stride
                crc = zlib.crc32(data[start:start + width * 3], crc)
            actual_crc = f"{crc & 0xffffffff:08X}"
            result.metadata += f"\n实际像素CRC32：{actual_crc} · {width}×{height} · {bpp}位"
            if actual_crc != expected_crc:
                result.message = "像素CRC32不匹配：清单校验未通过；已清除图片"
                return result
            if Image is None:
                result.message = "缺少Pillow，无法显示缩略图；请按README安装"
                return result
            with Image.open(io.BytesIO(data)) as source:
                if source.format != "BMP" or source.size != (width, height):
                    raise ValueError("BMP解码结果与清单不匹配")
                thumbnail = source.convert("RGB")
                thumbnail.thumbnail(THUMBNAIL_SIZE, Image.Resampling.LANCZOS)
            result.image = thumbnail
            result.message = "本地SHA256与像素CRC32均匹配项目清单；不代表板端已通过CRC验证"
        except (OSError, ValueError, TypeError, KeyError, struct.error) as exc:
            result.image = None
            result.message = f"本地预览不可用：{exc}；已清除图片"
        return result
