#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ci_check.py — FPGA_Project 仓库体检（CI 与本地共用）。

检查项（全部不依赖 Vivado，可在任意机器运行）：
  1. 文档命名规范   docs/ 下 Markdown 文件名须合规范（见 docs/README.md）
  2. 相对链接可解析  所有 Markdown 里的相对链接与图片必须指向真实存在的文件
  3. Python 语法    仓库内全部 .py 可编译
  4. .ps1 编码      仓库内全部 .ps1 必须带 UTF-8 BOM（坑账本 #17/#18）
  5. Tcl 可解析     仓库内全部 .tcl 可被 tclsh 解析（无 tclsh 时跳过）

用法：python scripts/ci_check.py    （在仓库根目录运行）
退出码：0 = 全过；1 = 有失败项
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAILS: list[str] = []
SKIPS: list[str] = []


def tracked_files() -> list[Path]:
    """仓库已跟踪文件（CI 与本地一致；git 不可用时退回全盘扫描）。"""
    try:
        out = subprocess.run(
            ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True
        ).stdout
        return [ROOT / p for p in out.splitlines() if p.strip()]
    except Exception:
        return [p for p in ROOT.rglob("*") if p.is_file() and ".git" not in p.parts]


# ---------- 1. 文档命名规范 ----------
ALLOWED_HEAD = {
    "阶段一", "阶段二", "阶段二前置", "阶段三", "阶段四", "阶段五",
    "前置", "参考", "里程碑", "汇报", "规划", "追踪", "结论", "架构", "导览",
}
SEG_HEAD = re.compile(r"^阶段[一二三四五](之[一二三四五六七八九十]+)?$")


def check_doc_names(files: list[Path]) -> None:
    bad = []
    for f in files:
        rel = f.relative_to(ROOT).as_posix()
        # 规范只约束仓库根的 docs/ 文档中心；工程内部 docs/（PROGRESS.md 等）不受约束
        if f.suffix != ".md" or not rel.startswith("docs/"):
            continue
        if f.name in ("README.md", "agent.md"):
            continue  # 目录级索引与会话入口豁免
        name = f.name
        head = name.split("_")[0]
        ok = (
            " " not in name
            and re.search(r"_\d{4}-\d{2}-\d{2}\.md$", name) is not None
            and (head in ALLOWED_HEAD or SEG_HEAD.match(head) is not None)
        )
        if not ok:
            bad.append(str(f.relative_to(ROOT)).replace("\\", "/"))
    if bad:
        FAILS.append("文档命名不合规范（须为 [阶段]_prj标识_概要_YYYY-MM-DD.md，禁空格）:\n    " + "\n    ".join(bad))


# ---------- 2. 相对链接可解析 ----------
LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")


def check_links(files: list[Path]) -> None:
    bad = []
    for f in files:
        if f.suffix != ".md" or not f.exists():
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        for m in LINK.finditer(text):
            t = m.group(1).strip()
            if t.startswith(("http://", "https://", "mailto:", "#")):
                continue
            t = t.split("#", 1)[0]
            if not t:
                continue
            # 占位符示例（文档里演示写法用）不当作真链接
            if re.search(r"[<>*]|\.\.\.|xxx", t):
                continue
            target = (f.parent / t).resolve()
            if not target.exists():
                bad.append(f"{f.relative_to(ROOT).as_posix()}  ->  {m.group(1)}")
    if bad:
        FAILS.append("相对链接指向不存在的文件:\n    " + "\n    ".join(sorted(set(bad))))


# ---------- 3. Python 语法 ----------
def check_python(files: list[Path]) -> None:
    bad = []
    for f in files:
        if f.suffix != ".py" or not f.exists():
            continue
        try:
            compile(f.read_text(encoding="utf-8", errors="replace"), str(f), "exec")
        except SyntaxError as e:
            bad.append(f"{f.relative_to(ROOT).as_posix()}:{e.lineno}  {e.msg}")
    if bad:
        FAILS.append("Python 语法错误:\n    " + "\n    ".join(bad))


# ---------- 4. .ps1 必须带 UTF-8 BOM ----------
def check_ps1_bom(files: list[Path]) -> None:
    bad = []
    for f in files:
        if f.suffix != ".ps1" or not f.exists():
            continue
        raw = f.read_bytes()
        # 仅当脚本含非 ASCII 字符时 BOM 才是必需的：纯 ASCII 脚本 PS 5.1 按任何编码读都一样
        if any(b > 0x7F for b in raw) and raw[:3] != b"\xef\xbb\xbf":
            bad.append(f.relative_to(ROOT).as_posix())
    if bad:
        FAILS.append(
            "PowerShell 脚本缺少 UTF-8 BOM（PS 5.1 读无 BOM 中文脚本按 CP936 解码必报语法错）:\n    "
            + "\n    ".join(bad)
        )


# ---------- 5. Tcl 可解析 ----------
def check_tcl(files: list[Path]) -> None:
    try:
        subprocess.run(["tclsh", "<<exit>>"], capture_output=True, check=True, text=True)
    except Exception:
        SKIPS.append("tclsh 不可用，跳过 Tcl 语法检查")
        return
    bad = []
    for f in files:
        if f.suffix != ".tcl" or not f.exists():
            continue
        script = f'if {{![info complete [read [open {{{f.as_posix()}}} r]]]}} {{exit 1}}'
        r = subprocess.run(["tclsh"], input=script, capture_output=True, text=True)
        if r.returncode != 0:
            bad.append(f.relative_to(ROOT).as_posix())
    if bad:
        FAILS.append("Tcl 脚本不完整（引号/括号未闭合）:\n    " + "\n    ".join(bad))


def main() -> int:
    files = tracked_files()
    print(f"仓库体检：{len(files)} 个已跟踪文件\n")
    check_doc_names(files)
    check_links(files)
    check_python(files)
    check_ps1_bom(files)
    check_tcl(files)

    for s in SKIPS:
        print(f"  [跳过] {s}")
    if FAILS:
        print(f"\n发现 {len(FAILS)} 类问题：")
        for i, msg in enumerate(FAILS, 1):
            print(f"\n[{i}] {msg}")
        print("\n=== CI: FAIL ===")
        return 1
    print("\n=== CI: PASS（全部检查通过）===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
