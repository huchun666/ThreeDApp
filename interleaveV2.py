import argparse
import os
from typing import List, Optional, Sequence, Tuple

import numpy as np
from PIL import Image


def _natural_key(s: str) -> List[object]:
    import re

    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


def _list_images(input_dir: str, exts: Sequence[str]) -> List[str]:
    exts_l = {e.lower().lstrip(".") for e in exts}
    files = []
    for name in os.listdir(input_dir):
        p = os.path.join(input_dir, name)
        if not os.path.isfile(p):
            continue
        ext = os.path.splitext(name)[1].lower().lstrip(".")
        if ext in exts_l:
            files.append(p)
    files.sort(key=lambda p: _natural_key(os.path.basename(p)))
    return files


def _load_rgb(path: str, size: Optional[Tuple[int, int]]) -> np.ndarray:
    img = Image.open(path).convert("RGB")
    if size is not None and img.size != size:
        img = img.resize(size, Image.Resampling.LANCZOS)
    return np.asarray(img, dtype=np.uint8)


def interleave_views(
    imgs: Sequence[np.ndarray],
    *,
    val_x: float,
    val_tan: float,
    offset: float,
) -> np.ndarray:
    """
    imgs: [cnt, h, w, 3] 的 RGB uint8 图像序列（每张同尺寸）。

    输出：交织后的 RGB uint8 图像 [h, w, 3]。
    """
    if len(imgs) < 2:
        raise ValueError("至少需要 2 张视图图像才能交织。")

    stack = np.stack(imgs, axis=0)  # [cnt, h, w, 3]
    cnt, h, w, ch = stack.shape
    if ch != 3:
        raise ValueError("仅支持 RGB 三通道图片。")

    yy, xx = np.indices((h, w), dtype=np.float32)
    x_term = (w - 1 - xx) * 3.0
    y_term = yy * 3.0 * float(val_tan)

    out = np.empty((h, w, 3), dtype=np.uint8)
    for c in range(3):  # 0=R,1=G,2=B
        base = offset + y_term + x_term + (2 - c)
        frac = (np.mod(base, float(val_x))) / float(val_x)  # [0,1)
        idx = (frac * cnt).astype(np.int32)
        idx = np.clip(idx, 0, cnt - 1)
        out[..., c] = stack[idx, yy.astype(np.int32), xx.astype(np.int32), c]

    return out


def interleave_by_columns(imgs: Sequence[np.ndarray], *, stride: int = 1) -> np.ndarray:
    """
    按“列”交织：第 x 列来自第 ((x/stride) % cnt) 张图。
    与 iOS 侧 InterlaceImage.swift 的默认行为一致（axis=columns）。
    """
    if len(imgs) < 2:
        raise ValueError("至少需要 2 张视图图像才能交织。")
    if stride <= 0:
        raise ValueError("stride 必须为正整数。")

    stack = np.stack(imgs, axis=0)  # [cnt, h, w, 3]
    cnt, h, w, ch = stack.shape
    if ch != 3:
        raise ValueError("仅支持 RGB 三通道图片。")

    # 对每个 x，选择一张图 idx[x]
    x = np.arange(w, dtype=np.int32)
    idx = ((x // int(stride)) % cnt).astype(np.int32)  # [w]
    out = np.empty((h, w, 3), dtype=np.uint8)
    # 以列为单位拷贝
    for xi in range(w):
        out[:, xi, :] = stack[idx[xi], :, xi, :]
    return out


def main() -> int:
    parser = argparse.ArgumentParser(
        description="将多机位截图生成交织图（lenticular interleave）。"
    )
    parser.add_argument("--input_dir", required=True, help="多机位截图文件夹路径")
    parser.add_argument("--output", required=True, help="输出交织图路径（.png/.jpg）")
    parser.add_argument(
        "--count",
        type=int,
        default=0,
        help="使用前 N 张图（0 表示使用文件夹内全部图片）",
    )
    parser.add_argument(
        "--exts",
        default="png,jpg,jpeg",
        help="允许的扩展名，逗号分隔（默认 png,jpg,jpeg）",
    )
    parser.add_argument("--val_x", type=float, required=True, help="条纹周期参数 val_x")
    parser.add_argument("--val_tan", type=float, required=True, help="倾斜参数 val_tan")
    parser.add_argument("--offset", type=float, default=0.0, help="相位偏移 offset")
    parser.add_argument(
        "--mode",
        choices=["formula", "columns"],
        default="formula",
        help="交织模式：formula=使用 val_x/val_tan/offset；columns=按列交织（与 iOS 默认一致）",
    )
    parser.add_argument(
        "--stride",
        type=int,
        default=1,
        help="columns 模式列步长（默认 1；第 x 列来自 ((x/stride)%%count)）",
    )
    parser.add_argument(
        "--size",
        default="",
        help="强制尺寸，格式 WxH（例如 1920x1080）。不填则使用第一张图的尺寸",
    )

    args = parser.parse_args()

    exts = [e.strip() for e in args.exts.split(",") if e.strip()]
    files = _list_images(args.input_dir, exts)
    if not files:
        raise SystemExit(f"在 `{args.input_dir}` 中没找到图片（exts={exts}）。")

    if args.count and args.count > 0:
        files = files[: args.count]

    if len(files) < 2:
        raise SystemExit("图片数量不足：至少需要 2 张。")

    size: Optional[Tuple[int, int]] = None
    if args.size.strip():
        try:
            w_s, h_s = args.size.lower().split("x", 1)
            size = (int(w_s), int(h_s))
        except Exception as e:
            raise SystemExit(f"--size 解析失败：{args.size}，应为 WxH，例如 1920x1080。") from e

    if size is None:
        with Image.open(files[0]) as im0:
            size = im0.size  # (w, h)

    imgs = [_load_rgb(p, size) for p in files]
    if args.mode == "columns":
        out = interleave_by_columns(imgs, stride=args.stride)
    else:
        out = interleave_views(
            imgs, val_x=args.val_x, val_tan=args.val_tan, offset=args.offset
        )
    Image.fromarray(out).save(args.output)
    print("交织图生成完成:", args.output)
    print("使用视图数量:", len(imgs), "尺寸:", out.shape[1], "x", out.shape[0])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
