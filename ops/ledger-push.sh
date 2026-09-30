#!/usr/bin/env bash
# ledger-push.sh — 台账仓提交脚本(见 docs/约束/台账写法.md §二、docs/约束/红线.md 第21条)
#
# 用法:
#   ledger-push.sh -m "提交说明"              # 正常提交(身份校验+pull --rebase+保护条目校验+push)
#   ledger-push.sh -m "提交说明" --relock       # 仅限 主R:重建保护清单后随本次提交一并推送
#   ledger-push.sh --relock-only               # 仅限 主R:只重建 ops/ledger-protected.lock,不提交不推送
#
# 环境变量:
#   BTD_GROUP    本仓库尚未设置 git identity 时,用它设置 user.name/user.email(仅本仓库,local config)
#   LEDGER_FILE  台账文件相对仓库根的路径,默认 交付台账.md
#
# 必须在台账仓(btd-ledger 的某个 clone)内运行,且本脚本与 ops/ledger-protected.lock
# 需位于同一个仓库的 ops/ 目录下(即随 btd-ledger 仓库一起分发)。

set -euo pipefail

VALID_GROUPS=("简历Agent组" "模面组" "后端组" "数据组" "部署安全组" "前端组" "小程序组" "法务组" "主R" "审计组")
LEDGER_FILE="${LEDGER_FILE:-交付台账.md}"

# 0930 副本自检（0930-数据-10 抓出台账仓 ops/ 副本落后主树，0927-小程序-19 是同件第一次）：主树 ops/ 那份是权威，
#   随 btd-ledger 分发的本份一旦与主树那份内容不同，就改为执行主树那份（lock 与判据按 cwd 仓库根取，不受影响）；
#   主树不在（别的机器）则照常用本份。判据用 cmp 比内容，不比 mtime；只重执行一次，防两份互指成环。
BTD_MAIN_LEDGER_PUSH="${BTD_MAIN_LEDGER_PUSH:-$HOME/btd/main/ops/ledger-push.sh}"
if [[ -z "${BTD_LEDGER_PUSH_NO_REEXEC:-}" && -f "$BTD_MAIN_LEDGER_PUSH" ]] && ! cmp -s "$BTD_MAIN_LEDGER_PUSH" "${BASH_SOURCE[0]}"; then
  echo "notice: 本份 ledger-push.sh 与主树 $BTD_MAIN_LEDGER_PUSH 内容不同（台账仓 ops/ 副本落后或超前），改为执行主树那份；请主R 同步副本" >&2
  BTD_LEDGER_PUSH_NO_REEXEC=1 exec bash "$BTD_MAIN_LEDGER_PUSH" "$@"
fi

die() {
  echo "拒绝:$*" >&2
  exit 1
}

note() {
  echo "notice: $*"
}

# ---------- 参数解析 ----------
RELOCK=0
RELOCK_ONLY=0
COMMIT_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --relock)
      RELOCK=1
      shift
      ;;
    --relock-only)
      RELOCK_ONLY=1
      shift
      ;;
    -m)
      [[ $# -ge 2 ]] || die "-m 需要一个提交说明参数"
      COMMIT_MSG="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      die "未知参数:$1"
      ;;
  esac
done

if [[ $RELOCK_ONLY -eq 0 ]]; then
  # -m 在「工作区干净但本地有未推提交」的续推场景不需要,晚一点在 b 步再校验
  true
fi

# ---------- 定位仓库 ----------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 git 仓库内,请在台账 clone(~/btd/ledger/<组>/)内运行"
cd "$REPO_ROOT"

LOCK_FILE_REL="ops/ledger-protected.lock"
LOCK_FILE="$REPO_ROOT/$LOCK_FILE_REL"

[[ -f "$LEDGER_FILE" ]] || die "找不到台账文件:$LEDGER_FILE(可用 LEDGER_FILE 环境变量覆盖)"

# ---------- 工具函数 ----------
sha256_of() {
  # stdin -> sha256 hex(不含文件名)
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

normalize_line() {
  # 去掉行尾空白/回车,内容本身不动(前导空白视为条目格式的一部分,予以保留)
  LC_ALL=en_US.UTF-8 sed -E 's/[[:cntrl:][:space:]]+$//'
}

label40() {
  LC_ALL=en_US.UTF-8 cut -c1-40
}

extract_protected_lines() {
  # 输出 "<行号>:<原始内容>",匹配含 🔒 或 "codex 终审边界细则" 的整行
  local file="$1"
  LC_ALL=en_US.UTF-8 grep -n -E '🔒|codex 终审边界细则' "$file" || true
}

# 生成当前台账文件中所有保护条目的 "hash<TAB>label40" 表,写入 $2
generate_current_tsv() {
  local file="$1"
  local out="$2"
  : > "$out"
  while IFS= read -r rawline; do
    [[ -z "$rawline" ]] && continue
    local content="${rawline#*:}"
    local norm
    norm="$(printf '%s' "$content" | normalize_line)"
    local h
    h="$(printf '%s' "$norm" | sha256_of)"
    local lbl
    lbl="$(printf '%s' "$norm" | label40)"
    printf '%s\t%s\n' "$h" "$lbl" >> "$out"
  done < <(extract_protected_lines "$file")
}

regenerate_lock() {
  # relock 不豁免"codex 终审边界细则 只许出现一次"这条今天生效的规则——
  # 否则 relock 可能把一次误操作(比如条目被复制成两份)悄悄固化进新锁,
  # 要等下一次普通 push 才会被发现。
  local codex_count
  codex_count="$(LC_ALL=en_US.UTF-8 grep -c "codex 终审边界细则" "$LEDGER_FILE" || true)"
  [[ "${codex_count:-0}" -eq 1 ]] || die "relock 中止:codex 终审边界细则 出现次数应为 1,当前为 ${codex_count:-0}"

  local tmp
  tmp="$(mktemp)"
  generate_current_tsv "$LEDGER_FILE" "$tmp"
  mkdir -p "$(dirname "$LOCK_FILE")"
  mv "$tmp" "$LOCK_FILE"
  chmod 644 "$LOCK_FILE"
  wc -l < "$LOCK_FILE" | tr -d ' '
}

# ---------- a. 身份校验 ----------
LOCAL_NAME="$(git config --local --get user.name 2>/dev/null || true)"
if [[ -z "$LOCAL_NAME" && -n "${BTD_GROUP:-}" ]]; then
  git config user.name "$BTD_GROUP"
  git config user.email "${BTD_GROUP}@btd.local"
fi

CUR_NAME="$(git config user.name 2>/dev/null || true)"
[[ -n "$CUR_NAME" ]] || die "身份未设置:git config user.name 为空,且未提供 BTD_GROUP 环境变量"

IS_VALID_GROUP=0
for g in "${VALID_GROUPS[@]}"; do
  if [[ "$CUR_NAME" == "$g" ]]; then
    IS_VALID_GROUP=1
    break
  fi
done
[[ $IS_VALID_GROUP -eq 1 ]] || die "身份不是组名:$CUR_NAME"

if [[ $RELOCK -eq 1 || $RELOCK_ONLY -eq 1 ]]; then
  [[ "$CUR_NAME" == "主R" ]] || die "只有 主R 可以执行 relock(当前身份:$CUR_NAME)"
fi

echo "身份:$CUR_NAME"

# ---------- --relock-only:只重建锁文件,不提交不推送 ----------
if [[ $RELOCK_ONLY -eq 1 ]]; then
  n="$(regenerate_lock)"
  echo "已重新生成 $LOCK_FILE_REL(共 $n 条保护条目),未提交、未推送。"
  exit 0
fi

# ---------- b. 工作区改动只能是台账文件(--relock 时额外放行锁文件) ----------
BAD_FILES=()
HAS_CHANGE=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  HAS_CHANGE=1
  path="${line:3}"
  if [[ "$path" == *" -> "* ]]; then
    path="${path##* -> }"
  fi
  if [[ "$path" == "$LEDGER_FILE" ]]; then
    continue
  fi
  if [[ $RELOCK -eq 1 && "$path" == "$LOCK_FILE_REL" ]]; then
    continue
  fi
  BAD_FILES+=("$path")
done < <(git -c core.quotePath=false status --porcelain)

# 上次 commit 成功但 push 失败(远端在 fetch→push 窗口内前进)会留下"工作区干净、
# 本地领先 origin/main"的残留;这时不是"无改动",而是要续推(rebase 后再 push)。
RESUME_PUSH=0
if [[ $HAS_CHANGE -eq 0 ]]; then
  git fetch -q origin || die "git fetch origin 失败"
  AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
  [[ "$AHEAD" -gt 0 ]] || die "无改动可提交(工作区干净,本地也无未推提交)"
  note "工作区干净但本地领先 origin/main $AHEAD 笔(上次 push 未成功的残留),续推"
  RESUME_PUSH=1
else
  [[ -n "$COMMIT_MSG" || $RELOCK_ONLY -eq 1 ]] || die "缺少 -m 提交说明"
fi
if [[ ${#BAD_FILES[@]} -gt 0 ]]; then
  die "工作区改动不止 $LEDGER_FILE:${BAD_FILES[*]}"
fi

# ---------- c. fetch + pull --rebase ----------
# 台账文件此刻多半是未提交的改动。不用 `--autostash`:rebase 内置的
# autostash 回放冲突时并不会让外层命令以非零退出(已实测:冲突标记
# <<<<<<< 会被就地留在文件里、随后被当成"改动"一起提交推送到
# origin/main),这正是红线21明令禁止的"自动解决"。改为手工
# stash → pull --rebase → 按 sha stash apply,apply 的退出码才诚实反映冲突。
# --relock 时锁文件也可能是脏的(新建/改写,还未提交),必须和台账文件一起
# 暂存,否则接下来的 pull --rebase 会因为锁文件的未提交改动直接报错退出
# (已实测:relock-only 生成锁文件后紧接着 --relock,若只暂存台账文件,
# pull 会报 "cannot pull with rebase: You have unstaged changes")。
STASH_PATHS=("$LEDGER_FILE")
if [[ $RELOCK -eq 1 ]]; then
  STASH_PATHS+=("$LOCK_FILE_REL")
fi

# 还原一律按 sha 指名(apply + drop),不用无参 pop:pop 弹的是栈顶,栈里还留着历次 pop 冲突后
# 没清的残留(0927-部署-31 报一份 clone 里积了 18 条),栈顶未必是本次那条;tag 带组名+时间+pid,
# 让 stash list 里能认出是谁的哪一次。各组台账目录是独立 clone,栈不跨组共用,但残留同样会错位。
STASHED=0
STASH_SHA=""
if [[ -n "$(git status --porcelain -u -- "${STASH_PATHS[@]}")" ]]; then
  STASH_TAG="ledger-push:${CUR_NAME}:$(date +%Y%m%dT%H%M%S):$$:${STASH_PATHS[*]}"
  if ! git stash push -u -q -m "$STASH_TAG" -- "${STASH_PATHS[@]}"; then
    die "本地台账改动暂存失败(git stash push)"
  fi
  STASH_SHA="$(git stash list --format='%H %gs' | grep -F -- "$STASH_TAG" | head -1 | cut -d' ' -f1 || true)"
  [[ -n "$STASH_SHA" ]] || die "stash 已 push 但在 git stash list 里找不到本次那条(tag=$STASH_TAG),已中止"
  STASHED=1
fi
# 按 sha 还原本次那条;成功即 drop,失败(冲突)保留并返回非零,与 pop 语义一致但不会弹错条目。
# drop 只认 stash@{n} 不认裸 sha(实测 drop <sha> 报「不是 stash 引用」),所以 apply 成功后再按 sha 反查
# 当下的 stash@{n} 去 drop;反查失败只留一条残留,不影响提交。
restore_stash() {
  git stash apply -q "$STASH_SHA" || return 1
  local ref
  ref="$(git stash list --format='%H %gd' | grep -F -- "$STASH_SHA" | head -1 | cut -d' ' -f2 || true)"
  if [[ -n "$ref" ]]; then git stash drop -q "$ref" || true; fi
}

if ! git fetch origin; then
  # fetch 失败时台账改动已在 stash 里,不还原就会让调用方看到"工作区干净"
  # 而误以为丢了改动(0924 实测:一次瞬时 fetch 失败后重跑报"无改动可提交")。
  msg="git fetch origin 失败"
  if [[ $STASHED -eq 1 ]]; then
    if restore_stash; then
      msg="$msg;本地台账改动已还原到工作区,原样重跑即可"
    else
      msg="$msg;本地台账改动仍在 git stash $STASH_SHA,需手工 git stash apply $STASH_SHA"
    fi
  fi
  die "$msg"
fi

if ! git pull --rebase origin main; then
  # 只有真有未合并路径才是冲突;pull 自带的 fetch 失败(网络抖动)也会让它非零退出,
  # 那种情况把 stash 还原、告诉调用方原样重跑,别报成"冲突"(0924 实测两者被混报)。
  if [[ -n "$(git ls-files -u)" ]]; then
    git rebase --abort >/dev/null 2>&1 || true
    msg="pull --rebase 冲突,已中止,需人工处理(不自动解决)"
    [[ $STASHED -eq 1 ]] && msg="$msg;本地改动在 git stash $STASH_SHA"
    die "$msg"
  fi
  git rebase --abort >/dev/null 2>&1 || true
  msg="pull --rebase 失败但无冲突(多半是 fetch 网络失败)"
  if [[ $STASHED -eq 1 ]]; then
    if restore_stash; then
      msg="$msg;本地台账改动已还原到工作区,原样重跑即可"
    else
      msg="$msg;本地台账改动仍在 git stash $STASH_SHA,需手工 git stash apply $STASH_SHA"
    fi
  fi
  die "$msg"
fi

if [[ $STASHED -eq 1 ]]; then
  if ! restore_stash; then
    die "本地台账改动与远端最新版本冲突(stash apply 冲突),已中止且未提交;改动仍保留在 git stash $STASH_SHA 中(不自动解决)。处置:git checkout HEAD -- $LEDGER_FILE 回到远端最新(裸 checkout -- 在 unmerged 路径上会报错),再重跑你的幂等写入脚本;别无参 git stash pop,栈顶未必是这条"
  fi
fi

# 双保险:任何原因导致索引里仍留有未合并路径,一律拒绝提交,不代为解决。
if [[ -n "$(git ls-files -u)" ]]; then
  die "工作区存在未合并的冲突(git ls-files -u 非空),已中止,需人工处理(不自动解决)"
fi

# ---------- d. 保护条目校验 / --relock 重建 ----------
if [[ $RELOCK -eq 1 ]]; then
  n="$(regenerate_lock)"
  echo "已重新生成 $LOCK_FILE_REL(共 $n 条保护条目),将随本次提交一并写入。"
else
  [[ -f "$LOCK_FILE" ]] || die "找不到锁文件:$LOCK_FILE_REL"

  CUR_TSV="$(mktemp)"
  trap 'rm -f "$CUR_TSV"' EXIT
  generate_current_tsv "$LEDGER_FILE" "$CUR_TSV"

  while IFS=$'\t' read -r lh llabel; do
    [[ -z "$lh" ]] && continue
    if ! LC_ALL=en_US.UTF-8 grep -qxF "$lh" <(cut -f1 "$CUR_TSV"); then
      die "保护条目被改动或删除:$llabel"
    fi
  done < "$LOCK_FILE"

  CODEX_COUNT="$(LC_ALL=en_US.UTF-8 grep -c "codex 终审边界细则" "$LEDGER_FILE" || true)"
  [[ "${CODEX_COUNT:-0}" -eq 1 ]] || die "codex 终审边界细则 出现次数应为 1,当前为 ${CODEX_COUNT:-0}"

  while IFS=$'\t' read -r ch clabel; do
    [[ -z "$ch" ]] && continue
    if ! LC_ALL=en_US.UTF-8 grep -qxF "$ch" <(cut -f1 "$LOCK_FILE"); then
      note "发现未登记的保护条目(如属新增裁决,建议主R事后执行 ledger-relock.sh):$clabel"
    fi
  done < "$CUR_TSV"

  rm -f "$CUR_TSV"
  trap - EXIT
fi

# ---------- d2. 表格行列数(0927-主R-33,起因 0927-后端-06) ----------
# 只判本次相对 HEAD 新增/改动的行(此时已 rebase 到 origin/main,HEAD 就是别人最新推的),存量 453 行不回头清。
# 判据与本脚本同目录,找不到直接拒:判据静默缺席比拦错更糟(0926 开关型判据两侧不对称)。
if [[ $RESUME_PUSH -eq 0 ]]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$SELF_DIR/ledger-table-lint.py" ]] || die "找不到判据 $SELF_DIR/ledger-table-lint.py(应与本脚本同目录;用 ~/btd/main/ops/ledger-push.sh)"
  if ! python3 "$SELF_DIR/ledger-table-lint.py" "$LEDGER_FILE" --changed HEAD; then
    die "本次改动的表格行列数与表头不一致或表内插了空行(上面逐行列出);竖线写成 \\| 或改成指针,命令与正则不进表行(台账写法.md 三)"
  fi
fi

# ---------- e. commit + push + 验证并入 ----------
if [[ $RESUME_PUSH -eq 0 ]]; then
  git add -- "$LEDGER_FILE"
  if [[ $RELOCK -eq 1 ]]; then
    git add -- "$LOCK_FILE_REL"
  fi
  git commit -m "$COMMIT_MSG" || die "提交失败(可能无实际改动)"
fi

if ! git push origin HEAD:main; then
  die "push 失败"
fi

git fetch origin main
if ! git merge-base --is-ancestor HEAD origin/main; then
  echo "push 未并入"
  exit 2
fi

echo "推送成功,已并入 main。"
