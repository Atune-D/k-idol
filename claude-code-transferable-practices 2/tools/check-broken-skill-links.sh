#!/usr/bin/env bash
# 检查 ~/.claude/skills 下是否存在断链的符号链接。
# 清理 skill 之后必跑——删掉软链目标会让在用的 skill 静默失效。
set -u
DIR="${1:-$HOME/.claude/skills}"
cd "$DIR" || { echo "目录不存在: $DIR"; exit 1; }
broken=0
for f in *; do
  if [ -L "$f" ] && [ ! -e "$f" ]; then
    echo "断链: $f -> $(readlink "$f")"
    broken=$((broken+1))
  fi
done
if [ "$broken" -eq 0 ]; then echo "无断链 ✅"; else echo "共 $broken 个断链 ❌"; exit 1; fi
