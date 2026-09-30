#!/usr/bin/env python3
# 台账表格行列数判据(0927-主R-33,起因 0927-后端-06):GFM 渲染下数据行单元格多于表头会整格丢内容
# (gh api /markdown 实测),少于表头只是格式不齐;两种都判不一致。反引号不保护竖线,只有 \| 不算分隔。
#
# 用法:
#   python3 ops/ledger-table-lint.py <台账文件>                 # 全文扫,打印每处不一致,退出码 1 有不一致 / 0 全齐
#   python3 ops/ledger-table-lint.py <台账文件> --changed <ref>  # 只判相对 <ref> 新增或改动的行(git diff -U0),ledger-push 用这个
# 表的范围按「意图」不按 GFM:从表头行 + 分隔行开始,到下一个表头或下一个任意级别的标题行(#、##、####…)为止,其间所有以 | 开头的行都算这张表的行。
# 0927 断表条件从「## 」放宽到任意级别标题(0927-数据-1 抓出):② 节按 #### <组名> 分块,原来 140 行法务组那张 5 列表的范围一直延续到 165 行数据组自己的表头,
# 数据组段首的行被按 5 列判。放宽后不在任何表内的 | 行(段首没有表头就写行)另判「表行无表头」,不然这些行就没人判;新行一律插在本组表头之后。
# 不按 GFM 的原因:GFM 在第一个空行就断表,而台账 ③ 在 1751 行处有个存量空行,按 GFM 后面约 800 行(含大家每天追加的新行)
# 全在表外、判据会对追加位盲;存量不回头清(0927-主R-33),ledger-push 只拦本次改动行,全文模式给主R 看趋势用。
# 另判一种:本次改动引入的空行落在两行 | 之间(下一个非空行仍是 | 行),GFM 会从这里断表、把后面的行渲染成正文。
# ③ 通信节没有表头(历史如此,0925 起大家统一写六格 | 日期 | 发→收 | 件号 | 标签 | 事由 | 状态 |),按 SECTION_WIDTH 给定宽度判,
# 节内偶然长得像表头的行(1126 行后面有人留了一行 |------|)不当表头,否则整节按错宽度判。
import re, subprocess, sys

# 无表头的节:节标题前缀 -> 该节所有 | 行的固定格数(台账写法.md 三)
SECTION_WIDTH = {"## ③": 6}

HEAD = re.compile(r"#{1,6} ")
SEP = re.compile(r"\|?[\s:\-|]*-[\s:\-|]*\|?$")


def cells(line):
    parts = re.split(r"(?<!\\)\|", line.strip())
    if parts and parts[0] == "":
        parts = parts[1:]
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return len(parts)


def scan(lines):
    """返回 [(行号1起, 表头列数, 本行列数)] 的列数不一致清单、[行号] 的表内空行清单、[行号] 的无表头表行清单、表的个数。"""
    bad, blanks, orphans, tables, i, n = [], [], [], 0, 0, len(lines)
    while i < n:
        fixed = next((w for k, w in SECTION_WIDTH.items() if lines[i].startswith(k)), None)
        if fixed is not None:
            tables += 1
            j = i + 1
            while j < n and not lines[j].startswith("## "):
                if lines[j].startswith("|") and not SEP.match(lines[j]):
                    c = cells(lines[j])
                    if c != fixed:
                        bad.append((j + 1, fixed, c))
                j += 1
            i = j
            continue
        if lines[i].startswith("|") and i + 1 < n and lines[i + 1].startswith("|") and SEP.match(lines[i + 1]):
            tables += 1
            width = cells(lines[i])
            j = i + 2
            while j < n and not HEAD.match(lines[j]) and not (
                lines[j].startswith("|") and j + 1 < n and lines[j + 1].startswith("|") and SEP.match(lines[j + 1])
            ):
                if lines[j].startswith("|"):
                    c = cells(lines[j])
                    if c != width:
                        bad.append((j + 1, width, c))
                elif lines[j].strip() == "":
                    k = j + 1
                    while k < n and lines[k].strip() == "":
                        k += 1
                    # 0928 下一个非空行若本身是新表头(其后紧跟分隔行),这个空行是两表之间的必要空行,不报(0928-数据-1 抓出的误报)
                    if k < n and lines[k].startswith("|") and not (k + 1 < n and lines[k + 1].startswith("|") and SEP.match(lines[k + 1])):
                        blanks.append(j + 1)
                j += 1
            i = j
        else:
            # 固定宽度节以外、不在任何表范围内的 | 行:没有表头可比,单独判(分隔行形状的孤行不算)
            if lines[i].startswith("|") and not SEP.match(lines[i]):
                orphans.append(i + 1)
            i += 1
    return bad, blanks, orphans, tables


def changed_lines(path, ref):
    out = subprocess.run(["git", "diff", "-U0", ref, "--", path], capture_output=True, text=True, check=True).stdout
    s = set()
    for m in re.finditer(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", out, re.M):
        start, cnt = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
        s.update(range(start, start + cnt))
    return s


def main():
    if len(sys.argv) < 2:
        print(__doc__ or "用法见文件头注释"); sys.exit(2)
    path = sys.argv[1]
    ref = sys.argv[sys.argv.index("--changed") + 1] if "--changed" in sys.argv else None
    lines = open(path, encoding="utf-8").read().split("\n")
    bad, blanks, orphans, tables = scan(lines)
    if ref is not None:
        only = changed_lines(path, ref)
        bad = [b for b in bad if b[0] in only]
        blanks = [b for b in blanks if b in only]
        orphans = [o for o in orphans if o in only]
    for ln, w, c in bad:
        print(f"{path}:{ln}: 表头 {w} 列,本行 {c} 列({'多' if c > w else '少'} {abs(c - w)});单元格里的竖线写成 \\| 或改成指针")
    for ln in blanks:
        print(f"{path}:{ln}: 表内空行,后面还有表行;GFM 会从这里断表,删掉这个空行")
    for ln in orphans:
        print(f"{path}:{ln}: 表行不在任何表内(上面到最近一个标题之间没有表头);把行插到本组表头之后")
    more = sum(1 for _, w, c in bad if c > w); less = len(bad) - more
    print(f"表 {tables} 个;{'本次改动行' if ref is not None else '全文'} 列数不一致 {len(bad)}(多列 {more} / 少列 {less}),表内空行 {len(blanks)},无表头表行 {len(orphans)}")
    sys.exit(1 if (bad or blanks or orphans) else 0)


if __name__ == "__main__":
    main()
