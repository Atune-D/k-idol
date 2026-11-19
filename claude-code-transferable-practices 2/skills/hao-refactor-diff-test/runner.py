#!/usr/bin/env python3
"""
hao-refactor-diff-test 对比引擎（通用，不锁定具体项目）。

给定一个项目根目录与两个代码版本（old / new ref），起两个版本、连同一个库，
按 账号 × path 矩阵抓取页面 HTML、清洗、diff，并按 expected-diffs 分三档
（CONSISTENT / EXPECTED / UNEXPECTED），产出审计文档。仅在存在 UNEXPECTED 时退出码非 0。

项目差异（怎么起服务、怎么登录、符号前缀等）全部来自项目自己的
<project>/tools/refactor-diff-test/refactor-diff-test-config.json，本引擎不含任何项目关键字。

用法：
  python3 runner.py --project-root <abs> --old <ref> --new <ref|WORKINGTREE> [--allow-migration-diff] [--no-prewarm]
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import shutil
import time
import difflib
from datetime import datetime

TOOL_SUBDIR = os.path.join("tools", "refactor-diff-test")


# ----------------------------- 读取与透明化 -----------------------------

def tool_dir(project_root):
    return os.path.join(project_root, TOOL_SUBDIR)


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def file_hash(path):
    return hashlib.sha256(read_text(path).encode("utf-8")).hexdigest()[:12]


def load_jsonl(path):
    """读 JSONL：# 开头或空行跳过；返回 dict 列表。"""
    rows = []
    if not os.path.exists(path):
        return rows
    for i, line in enumerate(read_text(path).splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        try:
            rows.append(json.loads(s))
        except json.JSONDecodeError as e:
            die(f"{os.path.basename(path)} 第 {i} 行 JSON 非法: {e}")
    return rows


def load_config(project_root):
    p = os.path.join(tool_dir(project_root), "refactor-diff-test-config.json")
    if not os.path.exists(p):
        die(f"未找到 {p}；该项目尚未接入 refactor-diff-test，请先写 config（见 skill onboarding）。")
    return json.loads(read_text(p)), p


def print_sources(project_root, config_path):
    """铁规则透明化：打印实际使用的工具文件绝对路径 + hash，杜绝暗中用错版本。"""
    td = tool_dir(project_root)
    print("== 使用的工具文件（均取自当前工作树，与被对比的 commit 无关）==")
    for name in ["refactor-diff-test-config.json", "refactor-diff-test-paths.jsonl",
                 "refactor-diff-test-accounts.jsonl", "refactor-diff-test-expected-diffs.jsonl"]:
        p = os.path.join(td, name)
        if os.path.exists(p):
            n = len([l for l in read_text(p).splitlines() if l.strip() and not l.strip().startswith("#")])
            print(f"   {p}  (hash={file_hash(p)}, 有效行={n})")
        else:
            print(f"   {p}  (缺失)")
    print()


def die(msg, code=2):
    print(f"[refactor-diff-test] 错误: {msg}", file=sys.stderr)
    sys.exit(code)


def run(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, **kw)


# ----------------------------- 迁移检测 -----------------------------

def detect_migration_changes(project_root, old_ref, new_ref, config):
    """比对两 ref 间 migration 路径变化；有变化返回文件列表（供警告）。"""
    globs = config.get("migrationPaths", [
        "app/database/migrations", "database/migrations",
        "app/config/**/migrations", "migrations",
    ])
    base = new_ref if new_ref != "WORKINGTREE" else "HEAD"
    changed = []
    for g in globs:
        r = run(["git", "-C", project_root, "diff", "--name-only", old_ref, base, "--", g])
        changed += [x for x in r.stdout.splitlines() if x.strip()]
    return sorted(set(changed))


# ----------------------------- 起/停服务 -----------------------------

def render(template, mapping):
    out = template
    for k, v in mapping.items():
        out = out.replace("{" + k + "}", str(v))
    return out


def prepare_worktree(project_root, ref, tmpbase):
    """checkout 一个 ref 到临时 worktree；WORKINGTREE 直接用 project_root。"""
    if ref == "WORKINGTREE":
        return project_root, None
    wt = os.path.join(tmpbase, "wt_" + re.sub(r"[^0-9a-zA-Z]", "_", ref))
    r = run(["git", "-C", project_root, "worktree", "add", "--detach", wt, ref])
    if r.returncode != 0:
        die(f"git worktree add {ref} 失败: {r.stderr.strip()}")
    return wt, wt


def start_server(config, slot, worktree_path, port, project_root):
    recipe = config["serveRecipe"]
    mapping = {"worktreePath": worktree_path, "port": port, "slot": slot,
               "projectRoot": project_root, "toolDir": tool_dir(project_root)}
    cmd = render(recipe["start"], mapping)
    r = run(cmd)
    if r.returncode != 0:
        die(f"[{slot}] 启动服务失败: {cmd}\n{r.stderr.strip()}")
    # 等 ready
    ready = recipe.get("ready", {})
    url = render(ready.get("url", ""), mapping)
    timeout = int(ready.get("timeoutSeconds", 60))
    below = int(ready.get("statusBelow", 500))
    if url:
        for _ in range(timeout):
            rr = run(["curl", "-sS", "-o", os.devnull, "-w", "%{http_code}", url])
            if rr.stdout.strip().isdigit() and int(rr.stdout.strip()) < below:
                return
            time.sleep(1)
        die(f"[{slot}] 服务在 {timeout}s 内未就绪: {url}")


def stop_server(config, slot, worktree_path, port, project_root):
    recipe = config["serveRecipe"]
    cmd = render(recipe.get("stop", ""), {"worktreePath": worktree_path, "port": port, "slot": slot,
                                          "projectRoot": project_root, "toolDir": tool_dir(project_root)})
    if cmd.strip():
        run(cmd)


# ----------------------------- 登录 / 抓取 -----------------------------

def prepare_account(config, tool_directory, acc):
    """账号准备：有 accountRecipe + user_id → 跑 prepare（查 email + 非破坏性重置密码），
    返回 (username, password, restore_token)；否则用 acc 自带 username/password。
    prepare 失败返回 (None, None, None)。"""
    ar = config.get("accountRecipe")
    if ar and "user_id" in acc:
        cmd = render(ar["prepare"], {"toolDir": tool_directory, "user_id": acc["user_id"]})
        r = run(cmd)
        if r.returncode != 0:
            print(f"   账号准备失败 user_id={acc['user_id']}: {r.stderr.strip()}", file=sys.stderr)
            return None, None, None
        parts = r.stdout.strip().split("\t")
        if len(parts) < 2:
            return None, None, None
        return parts[0], parts[1], (parts[2] if len(parts) > 2 else None)
    return acc.get("username"), acc.get("password"), None


def restore_account(config, tool_directory, acc, restore_token):
    """测完还原账号（把密码写回原哈希）。"""
    ar = config.get("accountRecipe")
    if ar and restore_token is not None and "user_id" in acc:
        cmd = render(ar["restore"], {"toolDir": tool_directory, "user_id": acc["user_id"],
                                     "restoreToken": restore_token})
        run(cmd)


def login(config, port, username, password, cookiejar, tool_directory):
    """按 loginRecipe 登录，写 cookie 到 cookiejar。返回是否成功。
    支持两种：script（项目自带登录脚本，适合多步/复杂登录）或声明式单次 POST。"""
    rec = config["loginRecipe"]
    if "script" in rec:
        cmd = render(rec["script"], {"toolDir": tool_directory, "port": port,
                                     "username": username, "password": password, "cookieJar": cookiejar})
        return run(cmd).returncode == 0
    base = f"http://localhost:{port}"
    url = base + rec["loginPath"]
    fm = rec.get("fieldMap", {"username": "username", "password": "password"})
    data = []
    data.append(f"{fm['username']}={username}")
    data.append(f"{fm['password']}={password}")
    for k, v in rec.get("extraFields", {}).items():
        data.append(f"{k}={v}")
    args = ["curl", "-sS", "-c", cookiejar, "-b", cookiejar, "-o", os.devnull,
            "-w", "%{http_code}", "-X", rec.get("method", "POST")]
    for d in data:
        args += ["--data-urlencode", d]
    args.append(url)
    r = run(args)
    ok_below = int(rec.get("success", {}).get("statusBelow", 400))
    return r.stdout.strip().isdigit() and int(r.stdout.strip()) < ok_below


def fetch(port, path, cookiejar):
    """抓取一个页面，跟随 301（符号跳转在此透明解析）。返回 (final_url, status, body)。"""
    url = f"http://localhost:{port}{path}"
    with tempfile.NamedTemporaryFile("r", suffix=".html", delete=False, encoding="utf-8") as tf:
        body_path = tf.name
    args = ["curl", "-sS", "-L", "-b", cookiejar, "-c", cookiejar,
            "-o", body_path, "-w", "%{url_effective}\t%{http_code}", url]
    r = run(args)
    final_url, status = "", "000"
    if "\t" in r.stdout:
        final_url, status = r.stdout.strip().split("\t", 1)
    body = read_text(body_path)
    os.unlink(body_path)
    return final_url, status, body


def path_of(url):
    """从最终 URL 里剥掉 scheme://host:port，只留 /path?query（用于把新版解析出的真实 URL 套到旧版）。"""
    m = re.match(r"^https?://[^/]+(/.*)$", url or "")
    return m.group(1) if m else (url or "/")


# ----------------------------- 清洗 / diff / 分类 -----------------------------

def normalize_ports(html, ports):
    """两实例在不同端口，所有绝对 URL 都会带各自端口 → 内置归一化，消除这一固有噪音。"""
    for p in (ports.get("old"), ports.get("new")):
        if p:
            html = html.replace(f"localhost:{p}", "localhost:PORT")
    return html


def apply_strip(html, global_rules, path_rules):
    for rule in list(global_rules) + list(path_rules):
        html = re.sub(rule["pattern"], rule.get("replace", ""), html)
    return html


def is_expected(path, account_label, diff_text, expected_rows):
    for e in expected_rows:
        if e.get("path") not in (path, "*"):
            continue
        acc = e.get("account", "*")
        if acc not in ("*", account_label):
            continue
        m = e.get("match")
        if m is None or re.search(m, diff_text):
            return e
    return None


def make_diff(old_clean, new_clean):
    d = list(difflib.unified_diff(
        old_clean.splitlines(), new_clean.splitlines(),
        fromfile="old", tofile="new", lineterm="", n=1))
    return "\n".join(d)


# ----------------------------- 主流程 -----------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-root", required=True)
    ap.add_argument("--old", required=True)
    ap.add_argument("--new", required=True, help="ref 或 WORKINGTREE")
    ap.add_argument("--allow-migration-diff", action="store_true")
    ap.add_argument("--no-prewarm", action="store_true")
    ap.add_argument("--max-accounts", type=int, default=0, help="仅测前 N 个账号（0=全部）")
    ap.add_argument("--allow-no-sample", action="store_true",
                    help="显式豁免本轮的 NO_SAMPLE：默认 NO_SAMPLE 视为覆盖失败并非 0 退出，加此参数才放行")
    args = ap.parse_args()

    project_root = os.path.abspath(args.project_root)
    config, config_path = load_config(project_root)
    print_sources(project_root, config_path)

    td = tool_dir(project_root)
    path_rows = load_jsonl(os.path.join(td, "refactor-diff-test-paths.jsonl"))
    accounts = load_jsonl(os.path.join(td, "refactor-diff-test-accounts.jsonl"))
    expected = load_jsonl(os.path.join(td, "refactor-diff-test-expected-diffs.jsonl"))
    global_rules = next((r["global"] for r in path_rows if "global" in r), [])
    paths = [r for r in path_rows if "path" in r]
    if args.max_accounts > 0:
        accounts = accounts[:args.max_accounts]
    if not accounts:
        die("accounts 清单为空（refactor-diff-test-accounts.jsonl），无法登录对比。")
    if not paths:
        die("paths 清单为空。")

    # 迁移检测
    migr = detect_migration_changes(project_root, args.old, args.new, config)
    if migr:
        print("⚠️  检测到两个版本之间有 migration / schema 变化，这不是纯重构，共享库对比可能不可靠：")
        for f in migr:
            print(f"     {f}")
        if not args.allow_migration_diff:
            die("如确认无关，加 --allow-migration-diff 继续。", code=3)
        print("   （已 --allow-migration-diff 放行）\n")

    ports = config.get("ports", {"old": 9001, "new": 9002})
    symbolic_prefix = config.get("symbolicPrefix")  # 如 "/merchant"；符号路由只在新版解析，见抓取循环
    tmpbase = tempfile.mkdtemp(prefix="refactor-diff-test-")
    started = []
    results = []  # (account_label, path, verdict, final_old, final_new, diff, reason)

    # ★强制 HTML 存证★：每次抓取都把原始 HTML 落盘 + 记 MANIFEST，确保"真的抓到了真实页面"，
    # 而不是空白/跳过。清洗后内容过短则判 EMPTY（不算真实样本），堵掉"两个空白页相等=假通过"。
    # 一个时间戳贯穿整轮：本轮所有产物（审计 / MANIFEST / HTML）都进同一个 run-<ts>/ 目录，
    # 跑完再按判定重命名为 run-<ts>-PASS / -FAIL / -INCOMPLETE，一眼看出哪些文件属于同一次测试。
    run_ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = os.path.join(tool_dir(project_root), "reports", f"run-{run_ts}")
    html_dir = os.path.join(run_dir, "html")
    os.makedirs(html_dir, exist_ok=True)
    manifest = []  # (account, path, slot, http_status, raw_bytes, clean_bytes)
    MIN_HTML_BYTES = 200  # 清洗后低于此，视为空白/异常，非真实样本

    def dump_html(account_safe, path, slot, body):
        # html/<账号>/<path 槽>.<old|new>.html —— 按账号分子目录，old/new 相邻便于对照
        pslug = re.sub(r"[^0-9a-zA-Z]+", "_", path).strip("_")[:80] or "root"
        acc_dir = os.path.join(html_dir, account_safe)
        os.makedirs(acc_dir, exist_ok=True)
        fn = os.path.join(acc_dir, f"{pslug}.{slot}.html")
        with open(fn, "w", encoding="utf-8", errors="replace") as fh:
            fh.write(body or "")
        return fn

    try:
        # 起两版本
        for slot, ref in (("old", args.old), ("new", args.new)):
            wt, created = prepare_worktree(project_root, ref, tmpbase)
            start_server(config, slot, wt, ports[slot], project_root)
            started.append((slot, wt, created, ports[slot]))
            print(f"[{slot}] {ref} 已起在 :{ports[slot]}")

        # 账号 × path 矩阵
        for acc in accounts:
            label = acc.get("label", str(acc.get("user_id", acc.get("username", "?"))))
            username, password, restore_token = prepare_account(config, td, acc)
            if username is None:
                results.append((label, "(账号准备)", "PREP_FAIL", "", "", "accountRecipe prepare 失败", ""))
                continue
            try:
                safe = re.sub(r"[^0-9a-zA-Z]", "_", label)
                jar_old = os.path.join(tmpbase, f"jar_old_{safe}")
                jar_new = os.path.join(tmpbase, f"jar_new_{safe}")
                if not login(config, ports["old"], username, password, jar_old, td) or \
                   not login(config, ports["new"], username, password, jar_new, td):
                    results.append((label, "(登录)", "LOGIN_FAIL", "", "", "该账号在某一版本登录失败", ""))
                    continue

                # 预热（拿该账号在 new 上把 path 走一遍，让冷缓存落库）
                if not args.no_prewarm:
                    for pr in paths:
                        fetch(ports["new"], pr["path"], jar_new)

                for pr in paths:
                    path = pr["path"]
                    if symbolic_prefix and path.startswith(symbolic_prefix):
                        # 符号路由：resolver 只在新版存在。先在新版跟随 301 解析出真实 /deck URL，
                        # 再用这个真实 URL 同时请求新旧两版——旧 baseline 没有 resolver，不能直接请求符号 URL。
                        fu_new, st_new, body_new = fetch(ports["new"], path, jar_new)
                        if st_new in ("000", "404"):
                            # 新版都解析不出：该账号无此样本，或 resolver 未实现 → 无样本
                            dump_html(safe, path, "new", body_new)
                            manifest.append((label, path, "new", st_new, len(body_new or ""), 0))
                            results.append((label, path, "NO_SAMPLE", path, fu_new,
                                            f"新版未能解析符号 URL（{st_new}）：该账号无此样本或 resolver 未实现", ""))
                            continue
                        resolved = path_of(fu_new)   # 新版解析出的真实 /deck 路径（含 query）
                        fu_old, st_old, body_old = fetch(ports["old"], resolved, jar_old)
                    else:
                        fu_old, st_old, body_old = fetch(ports["old"], path, jar_old)
                        fu_new, st_new, body_new = fetch(ports["new"], path, jar_new)
                    # 无论结果如何，先把两版本原始 HTML 落盘 + 记 MANIFEST（含状态与字节数）——
                    # 保证事后能核对"确实抓到了真实内容"，任何空白/跳过都能在 MANIFEST 里现形。
                    f_old = dump_html(safe, path, "old", body_old)
                    f_new = dump_html(safe, path, "new", body_new)
                    clean_old = apply_strip(normalize_ports(body_old, ports), global_rules, pr.get("strip", []))
                    clean_new = apply_strip(normalize_ports(body_new, ports), global_rules, pr.get("strip", []))
                    manifest.append((label, path, "old", st_old, len(body_old or ""), len(clean_old)))
                    manifest.append((label, path, "new", st_new, len(body_new or ""), len(clean_new)))
                    if st_old in ("000", "404") and st_new in ("000", "404"):
                        results.append((label, path, "NO_SAMPLE", fu_old, fu_new, f"两版本均 {st_old}/{st_new}（可能无样本）", ""))
                        continue
                    # 空内容守卫：非 404 却清洗后过短 → 不是真实样本，判 EMPTY（失败），绝不当 CONSISTENT
                    if len(clean_old) < MIN_HTML_BYTES or len(clean_new) < MIN_HTML_BYTES:
                        results.append((label, path, "EMPTY", fu_old, fu_new,
                                        f"清洗后字节 old={len(clean_old)} new={len(clean_new)}（<{MIN_HTML_BYTES}）；"
                                        f"HTML 已存: {os.path.basename(f_old)} / {os.path.basename(f_new)}", ""))
                        continue
                    if clean_old == clean_new:
                        results.append((label, path, "CONSISTENT", fu_old, fu_new, "", ""))
                        continue
                    diff = make_diff(clean_old, clean_new)
                    e = is_expected(path, label, diff, expected)
                    if e:
                        results.append((label, path, "EXPECTED", fu_old, fu_new, diff, e.get("reason", "")))
                    else:
                        results.append((label, path, "UNEXPECTED", fu_old, fu_new, diff, ""))
            finally:
                restore_account(config, td, acc, restore_token)
    finally:
        for slot, wt, created, port in started:
            stop_server(config, slot, wt, port, project_root)
            if created:
                run(["git", "-C", project_root, "worktree", "remove", "--force", created])
        shutil.rmtree(tmpbase, ignore_errors=True)

    # 写 HTML 存证清单：一行一个 (账号,path,slot)，含 http 状态与原始/清洗字节数——
    # 用于肉眼核对每个页面都抓到了真实内容，任何 0 字节/空白都在这里暴露。
    manifest_path = os.path.join(run_dir, "MANIFEST.tsv")
    with open(manifest_path, "w", encoding="utf-8") as mf:
        mf.write("account\tpath\tslot\thttp\traw_bytes\tclean_bytes\n")
        for row in manifest:
            mf.write("\t".join(str(x) for x in row) + "\n")

    # 审计文档 + 汇总
    report_path = write_audit(run_dir, config, args, results, run_ts)
    counts = {}
    for r in results:
        counts[r[2]] = counts.get(r[2], 0) + 1

    # 覆盖率：哪些声明的 path 从头到尾一个样本都没拿到（NO_SAMPLE 铺满全账号）= 零覆盖目标。
    # 标了 "optional": true 的 path 允许无样本（如某账号确实没有该类数据）。
    optional_paths = {pr["path"] for pr in paths if pr.get("optional")}
    declared = [pr["path"] for pr in paths]
    got_sample = {p for (_l, p, v, *_r) in results if v in ("CONSISTENT", "EXPECTED", "UNEXPECTED")}
    uncovered = [p for p in declared if p not in got_sample and p not in optional_paths]
    # 非豁免路径上的 NO_SAMPLE 条数（覆盖失败的量）
    bad_no_sample = sum(1 for (_l, p, v, *_r) in results if v == "NO_SAMPLE" and p not in optional_paths)

    # 判定：先算出来，好用于目录命名与退出码。UNEXPECTED/EMPTY/登录/准备失败 = FAIL；
    # 否则有未豁免 NO_SAMPLE = INCOMPLETE；否则 PASS。
    hard_fail = (counts.get("UNEXPECTED", 0) + counts.get("LOGIN_FAIL", 0)
                 + counts.get("PREP_FAIL", 0) + counts.get("EMPTY", 0))
    if hard_fail:
        verdict, exit_code = "FAIL", 1
    elif bad_no_sample and not args.allow_no_sample:
        verdict, exit_code = "INCOMPLETE", 2
    else:
        verdict, exit_code = "PASS", 0

    # 汇总同时输出到控制台和 run_dir/summary.txt（每轮自包含、可回看）
    lines = ["== 结果 =="]
    for k in ["CONSISTENT", "EXPECTED", "UNEXPECTED", "EMPTY", "NO_SAMPLE", "LOGIN_FAIL", "PREP_FAIL"]:
        if counts.get(k):
            lines.append(f"   {k}: {counts[k]}")
    # 覆盖率行——永远有，先于判定，不让 NO_SAMPLE 被好数字盖过
    lines.append(f"   覆盖: {len(got_sample)}/{len(declared)} 路径实际取到样本"
                 + (f"；{len(uncovered)} 条零覆盖" if uncovered else "；全部已覆盖"))
    if uncovered:
        lines.append("   ⚠ 零覆盖路径（声明要测但一个样本都没拿到，通常是 resolver/路由未实现或 URL 失效）：")
        for p in uncovered:
            lines.append(f"       - {p}")
    lines.append(f"   对比: old={args.old}  new={args.new}")
    if verdict == "FAIL":
        lines.append(">>> 判定: FAIL（存在 UNEXPECTED / EMPTY 空白样本 / 登录 / 账号准备失败）")
    elif verdict == "INCOMPLETE":
        lines.append(f">>> 判定: INCOMPLETE —— {bad_no_sample} 个未取样的声明目标未覆盖，本轮不算通过。")
        lines.append("    NO_SAMPLE 不是“跳过”，是“该测的没测到”。请任选其一后重跑：")
        lines.append("      · 实现缺失的路由/resolver，让这些 path 真能访问；")
        lines.append("      · 对确实无数据的 path 在 paths.jsonl 里标 \"optional\": true；")
        lines.append("      · 本轮确认无所谓 → 加 --allow-no-sample 显式豁免。")
    else:
        lines.append(">>> 判定: PASS（声明目标全部覆盖且一致）")
    with open(os.path.join(run_dir, "summary.txt"), "w", encoding="utf-8") as sf:
        sf.write("\n".join(lines) + "\n")

    # 按判定重命名 run 目录：run-<ts>-<VERDICT>/，扫一眼就知道哪次成、哪次败
    final_dir = run_dir + "-" + verdict
    try:
        os.rename(run_dir, final_dir)
    except OSError:
        final_dir = run_dir  # 极端情况下重命名失败则保持原名，不影响结果

    print("\n" + "\n".join(lines))
    print(f"\n   本轮产物目录: {final_dir}/")
    print("     ├─ summary.txt   本汇总")
    print("     ├─ audit.md      逐页审计（UNEXPECTED/EXPECTED/NO_SAMPLE 明细）")
    print("     ├─ MANIFEST.tsv  每页 http 状态 + 字节数")
    print("     └─ html/<账号>/  每页新旧原始 HTML 存证")
    sys.exit(exit_code)


def write_audit(run_dir, config, args, results, ts):
    report_file = os.path.join(run_dir, "audit.md")
    lines = [
        f"# refactor-diff-test 审计 {ts}",
        "",
        f"- 项目: {config.get('projectCode','?')}",
        f"- 对比: old=`{args.old}`  new=`{args.new}`",
        f"- 账号×path 结果条数: {len(results)}",
        "",
        "## 需关注（UNEXPECTED / LOGIN_FAIL / PREP_FAIL）",
        "",
    ]
    unexp = [r for r in results if r[2] in ("UNEXPECTED", "LOGIN_FAIL", "PREP_FAIL")]
    if not unexp:
        lines.append("_无。全部为 CONSISTENT / EXPECTED / NO_SAMPLE。_")
    for label, path, verdict, fu_old, fu_new, diff, reason in unexp:
        lines += [f"### [{verdict}] 账号 `{label}` · `{path}`",
                  f"- old 最终 URL: {fu_old}", f"- new 最终 URL: {fu_new}",
                  "```diff", diff[:4000], "```", "",
                  "分类: ⬜ 待判定  → 若属预期内改动，登记进 expected-diffs（写 reason）；若属噪音，加 strip 规则；若疑似回归，查代码。", ""]
    lines += ["", "## 预期内（EXPECTED，已登记，不阻断）", ""]
    exp = [r for r in results if r[2] == "EXPECTED"]
    if not exp:
        lines.append("_无。_")
    for label, path, verdict, fu_old, fu_new, diff, reason in exp:
        lines += [f"### 账号 `{label}` · `{path}` — 原因: {reason}", "```diff", diff[:2000], "```", ""]
    # 无样本（NO_SAMPLE）也列出，便于区分「该账号确实无数据」与「resolver/路由失效」
    nosamp = [r for r in results if r[2] == "NO_SAMPLE"]
    lines += ["", "## 无样本（NO_SAMPLE）", ""]
    if not nosamp:
        lines.append("_无。_")
    for label, path, verdict, fu_old, fu_new, diff, reason in nosamp:
        lines.append(f"- 账号 `{label}` · `{path}` — {reason}")
    # 一致（CONSISTENT）只给计数，不逐条铺开
    consistent = [r for r in results if r[2] == "CONSISTENT"]
    lines += ["", f"## 一致（CONSISTENT）：{len(consistent)} 条", ""]
    with open(report_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return report_file


if __name__ == "__main__":
    main()
