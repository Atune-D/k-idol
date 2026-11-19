#!/usr/bin/env python3
"""审计 ~/.claude/skills 的使用率，输出可删候选。只读——不删任何东西。

用法:
    python3 audit-skill-usage.py [--days 180] [--json out.json]

判定"用过"取三层证据，缺一层就会误删:
  1. ~/.claude/history.jsonl 里手敲的 slash 命令（覆盖长，抓不到模型自动触发）
  2. ~/.claude/projects/**/*.jsonl 里的 Skill 工具调用（抓得到自动触发，覆盖期短）
  3. skill 之间的显式引用 + 传递闭包（保住被间接依赖的"零件型" skill）
另外把软链目标一并纳入保留集——删掉容器目录会让在用的软链断链。
"""
import argparse, datetime, json, os, re, sys
from collections import Counter

HOME = os.path.expanduser("~")
SKILLS = os.path.join(HOME, ".claude", "skills")
HISTORY = os.path.join(HOME, ".claude", "history.jsonl")
PROJECTS = os.path.join(HOME, ".claude", "projects")
CITE_TMPL = [r"/{n}\b", r"skills/{n}\b", r"\[\[{n}\]\]", r"[\"']{n}[\"']", r"`{n}`"]


def list_skills():
    return sorted(d for d in os.listdir(SKILLS)
                  if os.path.isdir(os.path.join(SKILLS, d)) or os.path.islink(os.path.join(SKILLS, d)))


def from_history(cutoff_ms):
    used = Counter()
    if not os.path.exists(HISTORY):
        return used
    with open(HISTORY, errors="ignore") as f:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                continue
            if (r.get("timestamp") or 0) < cutoff_ms:
                continue
            for m in re.finditer(r"/([a-zA-Z0-9:_-]+)", r.get("display", "")):
                used[m.group(1).split(":")[-1]] += 1
    return used


def from_transcripts():
    used = Counter()
    pat = re.compile(r'"skill"\s*:\s*"([a-zA-Z0-9:_-]+)"')
    for root, _, files in os.walk(PROJECTS):
        for fn in files:
            if not fn.endswith(".jsonl"):
                continue
            try:
                with open(os.path.join(root, fn), errors="ignore") as f:
                    for line in f:
                        if '"skill"' in line:
                            for m in pat.finditer(line):
                                used[m.group(1).split(":")[-1]] += 1
            except Exception:
                pass
    return used


def read_text(skill):
    buf = []
    for root, _, files in os.walk(os.path.join(SKILLS, skill)):
        for fn in files:
            if fn.endswith((".md", ".json", ".py", ".sh", ".ts", ".js")):
                try:
                    buf.append(open(os.path.join(root, fn), errors="ignore").read())
                except Exception:
                    pass
    return "\n".join(buf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=180)
    ap.add_argument("--json", default=None)
    a = ap.parse_args()

    cutoff = (datetime.datetime.now() - datetime.timedelta(days=a.days)).timestamp() * 1000
    skills = list_skills()
    slash, tool = from_history(cutoff), from_transcripts()
    used = {s for s in skills if slash.get(s) or tool.get(s)}

    texts = {s: read_text(s) for s in skills}
    calls = {}
    for owner in skills:
        t = texts[owner]
        calls[owner] = {s for s in skills
                        if s != owner and any(re.search(p.format(n=re.escape(s)), t) for p in CITE_TMPL)}

    # 软链: 被在用软链指向的目标也要保住
    for s in skills:
        p = os.path.join(SKILLS, s)
        if os.path.islink(p):
            tgt = os.readlink(p).split("/")[0]
            if tgt in skills:
                calls.setdefault(s, set()).add(tgt)

    keep, stack = set(used), list(used)
    while stack:
        for nxt in calls.get(stack.pop(), ()):
            if nxt not in keep:
                keep.add(nxt); stack.append(nxt)

    deletable = sorted(s for s in skills if s not in keep)
    print(f"总 {len(skills)} | 近 {a.days} 天直接用过 {len(used)} "
          f"| 传递闭包保留 {len(keep)} | 可删候选 {len(deletable)}")
    print(f"\n证据覆盖: history.jsonl {'✅' if os.path.exists(HISTORY) else '❌缺失'} | "
          f"会话记录 {len(tool)} 个 skill 有调用记录")
    print("\n=== 直接用过（按次数）===")
    for s in sorted(used, key=lambda x: -(slash.get(x, 0) + tool.get(x, 0))):
        print(f"  {s:38s} slash={slash.get(s,0):3d} tool={tool.get(s,0):3d}")
    print(f"\n=== 可删候选 {len(deletable)} 个（本脚本不执行删除）===")
    for s in deletable:
        print(f"  {s}")
    print("""
删除前务必:
  1. 全量备份:  tar -czf ~/.claude/backups/skills-$(date +%Y%m%d-%H%M%S).tar.gz -C ~/.claude skills
  2. 自己写的和第三方装的分开确认
  3. 删完跑断链自检:  ./check-broken-skill-links.sh""")
    if a.json:
        json.dump({"used": sorted(used), "keep": sorted(keep), "deletable": deletable,
                   "slash": dict(slash), "tool": dict(tool)},
                  open(a.json, "w"), ensure_ascii=False, indent=1)
        print(f"\n已写入 {a.json}")


if __name__ == "__main__":
    sys.exit(main())
