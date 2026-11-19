#!/usr/bin/env bash
#
# backend_diff_lib.sh —— 后端代码新旧等价性差分测试的通用 helper 库。
# 由每项目 tools/refactor-diff-test/ 下的任务 harness `source` 后调用。
#
# 设计见 skill SKILL.md 的「backend 模式」章节；首个实战实例见
# internal-project-backend/tools/refactor-diff-test/（含 TEST-LOG.md 全过程）。
#
# 哲学：
#   - 旧侧 = 独立转写自旧源码的 SQL（基准，不抄新代码）。
#   - 新侧 = 真实新代码路径（用 EQ_TMP_DB 环境变量重定向到一次性临时库）。
#   - 只读源库、只写临时库；等价单位是「实体集合」+「行形状字节」+「副作用」。
#
# 需要的环境变量（由 harness 或 refactor-diff-test-config 提供）：
#   EQ_SRC_HOST EQ_SRC_PORT EQ_SRC_USER EQ_SRC_PWD EQ_SRC_DB   # 只读源库连接
#   EQ_TMP_DB          # 一次性临时库名（如 tmp_db_equiv_<task>）
#   EQ_APP_DIR         # 被测应用根（含 artisan）
#   EQ_TZ              # 应用时区（如 Asia/Shanghai）——fixture 时间字面量按此生成
#
set -uo pipefail
EQ_PASS=0; EQ_FAIL=0

# ── 连接封装 ──────────────────────────────────────────────
eq_src_mysql() {  # 只读源库（禁止写！仅 SELECT/dump）
  MYSQL_PWD="$EQ_SRC_PWD" mysql -h"$EQ_SRC_HOST" -P"$EQ_SRC_PORT" -u"$EQ_SRC_USER" -N -B "$EQ_SRC_DB" -e "$1"
}
eq_tmp_mysql() {  # 一次性临时库（所有写落这里）
  MYSQL_PWD="$EQ_SRC_PWD" mysql -h"$EQ_SRC_HOST" -P"$EQ_SRC_PORT" -u"$EQ_SRC_USER" -N -B "$EQ_TMP_DB" -e "$1"
}
eq_admin_mysql() {  # 建/删库
  MYSQL_PWD="$EQ_SRC_PWD" mysql -h"$EQ_SRC_HOST" -P"$EQ_SRC_PORT" -u"$EQ_SRC_USER" -N -B -e "$1"
}

# ── 临时库搭建 ────────────────────────────────────────────
eq_reset_tmp_db() {  # 重建空临时库
  eq_admin_mysql "DROP DATABASE IF EXISTS \`$EQ_TMP_DB\`; CREATE DATABASE \`$EQ_TMP_DB\` CHARACTER SET utf8mb4;"
  echo "  [tmp] (重建) $EQ_TMP_DB"
}
eq_copy_all() {  # $1=表：全量拷（量小的维表）
  eq_admin_mysql "CREATE TABLE \`$EQ_TMP_DB\`.$1 LIKE \`$EQ_SRC_DB\`.$1;
                  INSERT INTO \`$EQ_TMP_DB\`.$1 SELECT * FROM \`$EQ_SRC_DB\`.$1;"
  echo "  [tmp] 全量拷 $1 ($(eq_tmp_mysql "SELECT COUNT(*) FROM $1") 行)"
}
eq_copy_where() {  # $1=表 $2=WHERE 子句：只拷必要子集（避开巨表全量）
  eq_admin_mysql "CREATE TABLE \`$EQ_TMP_DB\`.$1 LIKE \`$EQ_SRC_DB\`.$1;
                  INSERT INTO \`$EQ_TMP_DB\`.$1 SELECT * FROM \`$EQ_SRC_DB\`.$1 WHERE $2;"
  echo "  [tmp] 子集拷 $1 WHERE $2 ($(eq_tmp_mysql "SELECT COUNT(*) FROM $1") 行)"
}
eq_copy_struct() {  # $1=表：只拷结构（含唯一键/索引），数据留空
  eq_admin_mysql "CREATE TABLE \`$EQ_TMP_DB\`.$1 LIKE \`$EQ_SRC_DB\`.$1;"
  echo "  [tmp] 拷结构 $1（空）"
}
eq_apply_migration_col() {  # $1=表 $2=列定义：模拟「部署后」新增列（源库还没跑该迁移时必需）
  eq_tmp_mysql "ALTER TABLE $1 ADD COLUMN $2;"
  echo "  [tmp] 模拟迁移：$1 ADD $2"
}

# ── 新侧：真实新代码打到临时库 ─────────────────────────────
eq_artisan() {  # 真实后端 CLI 命令 / REPL，DB 重定向到临时库
  DB_DATABASE="$EQ_TMP_DB" php "$EQ_APP_DIR/artisan" "$@"
}

# ── 时间 fixture（★时区陷阱：必须用应用时区字面量，不能用 MySQL NOW()）──
eq_now_shift() {  # $1=分钟偏移(负=过去) -> 打印 EQ_TZ 时区的 'Y-m-d H:i:s'
  local m="$1"
  if [ "$m" -lt 0 ]; then TZ="$EQ_TZ" date -v"${m}M" +'%Y-%m-%d %H:%M:%S'
  else TZ="$EQ_TZ" date -v"+${m}M" +'%Y-%m-%d %H:%M:%S'; fi
}
eq_today() { TZ="$EQ_TZ" date +%Y-%m-%d; }
eq_yesterday() { TZ="$EQ_TZ" date -v-1d +%Y-%m-%d; }

# ── 比对断言（Layer 1 集合 / Layer 2 字节 / dry-run 交叉验证）──
eq_set_diff() {  # $1=命题名 $2=旧集合文件 $3=新集合文件（均已 sort）
  if diff -q "$2" "$3" >/dev/null; then
    echo "  ✅ PASS  $1  (集合逐行相等, n=$(wc -l <"$2" | tr -d ' '))"; EQ_PASS=$((EQ_PASS+1))
  else
    echo "  ❌ FAIL  $1"
    echo "     仅旧侧: $(comm -23 "$2" "$3" | tr '\n' ' ')"
    echo "     仅新侧: $(comm -13 "$2" "$3" | tr '\n' ' ')"; EQ_FAIL=$((EQ_FAIL+1))
  fi
}
eq_byte_eq() {  # $1=命题名 $2=实际 $3=期望（字节级）
  if [ "$2" = "$3" ]; then echo "  ✅ PASS  $1  [$2]"; EQ_PASS=$((EQ_PASS+1))
  else echo "  ❌ FAIL  $1"; echo "     实际: $2"; echo "     期望: $3"; EQ_FAIL=$((EQ_FAIL+1)); fi
}
eq_count_eq() {  # $1=命题名 $2=实际数 $3=期望数
  if [ "${2:-x}" = "$3" ]; then echo "  ✅ PASS  $1  ($2)"; EQ_PASS=$((EQ_PASS+1))
  else echo "  ❌ FAIL  $1  实际=$2 期望=$3"; EQ_FAIL=$((EQ_FAIL+1)); fi
}
eq_dryrun_crosscheck() {  # $1=命题名 $2=期望计数 $3...=真实命令(带 --dry-run，输出含 matched=N)
  local name="$1" exp="$2"; shift 2
  local got; got=$(eq_artisan "$@" 2>/dev/null | grep -oE 'matched=[0-9]+' | grep -oE '[0-9]+')
  eq_count_eq "$name (真实命令 dry-run matched == 谓词计数)" "$got" "$exp"
}

# ── 收尾横幅（覆盖率诚实：先报最坏，退出码 0/1）──
eq_report() {
  echo "════════════════════════════════════════════════════════"
  echo "总计: PASS=$EQ_PASS  FAIL=$EQ_FAIL"
  [ "$EQ_FAIL" -eq 0 ] && echo "判定: PASS ✅" || echo "判定: FAIL ❌"
  [ "$EQ_FAIL" -eq 0 ]
}

# ── 清理 ──────────────────────────────────────────────────
eq_drop_tmp_db() { eq_admin_mysql "DROP DATABASE IF EXISTS \`$EQ_TMP_DB\`;"; echo "  [tmp] 已清理 $EQ_TMP_DB"; }
