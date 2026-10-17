#!/usr/bin/env bash
#
# AutoDroid-WDA 真机验证（Phase 0）
#
# 用法:
#   autodroid/verify_device.sh http://192.168.1.23:8100
#   autodroid/verify_device.sh http://192.168.1.23:8100 --stability 60 --platform-repo ../AutoDroid
#
# 自动检查：
#   1. 执行器在线（GET /autodroid/status，即「点图标启动 WDA」是否成功）
#   2. 会话稳定性（在 --stability 秒内轮询，统计断连次数）
#   3. 运行日志可读（GET /autodroid/logs）
#   4. 完整自检（可选：调平台侧 backend.autojs_export.selftest 下发自检包并等结果）
# 需要人工确认的项（脚本无法替代）会在结尾列出。
set -uo pipefail

URL="${1:-}"
STABILITY_SECONDS=30
PLATFORM_REPO=""

shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --stability) STABILITY_SECONDS="${2:-30}"; shift 2 ;;
        --platform-repo) PLATFORM_REPO="${2:-}"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$URL" ]; then
    echo "用法: $0 <WDA_URL，如 http://192.168.1.23:8100> [--stability 秒数] [--platform-repo ../AutoDroid]" >&2
    exit 2
fi
URL="${URL%/}"

PYTHON="$(command -v python3 || true)"
pass_count=0
fail_count=0

ok()   { echo "  ✅ $1"; pass_count=$((pass_count + 1)); }
bad()  { echo "  ❌ $1"; fail_count=$((fail_count + 1)); }
warn() { echo "  ⚠️  $1"; }

json_field() {
    # $1: json 文本, $2: 字段名（仅支持顶层字段）
    [ -n "$PYTHON" ] || return 1
    printf '%s' "$1" | "$PYTHON" -c "import json,sys;print(json.load(sys.stdin).get('$2',''))" 2>/dev/null
}

echo "==> 目标: $URL"
echo

echo "[1/4] 执行器在线检查"
STATUS_JSON="$(curl -fsS --max-time 10 "$URL/autodroid/status" 2>/dev/null)"
if [ -z "$STATUS_JSON" ]; then
    bad "/autodroid/status 不可达：WDA 未启动或网络不通"
    echo "      处置：在手机上点 WebDriverAgentRunner 图标启动；确认手机与本次执行在同一网络；"
    echo "            若点图标闪退，先连一次 Xcode（重挂 Developer Disk Image）后重试。"
else
    ok "执行器在线：$(json_field "$STATUS_JSON" version 2>/dev/null || echo "$STATUS_JSON")"
    RUNNING="$(json_field "$STATUS_JSON" running 2>/dev/null || echo "")"
    case "$RUNNING" in
        True|true) warn "当前有脚本在执行中（running=true），稳定性检查可能受影响" ;;
    esac
fi

echo
echo "[2/4] 会话稳定性（${STABILITY_SECONDS}s 内每 2s 轮询）"
if [ -z "$STATUS_JSON" ]; then
    warn "跳过（执行器离线）"
else
    probes=0
    drops=0
    deadline=$(( $(date +%s) + STABILITY_SECONDS ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        probes=$((probes + 1))
        if ! curl -fsS --max-time 5 "$URL/autodroid/status" >/dev/null 2>&1; then
            drops=$((drops + 1))
        fi
        sleep 2
    done
    if [ "$drops" -eq 0 ]; then
        ok "探测 $probes 次全部成功，会话稳定"
    else
        bad "探测 $probes 次中有 $drops 次失败：会话不稳定（内存压力或 tunnel 问题常见）"
        echo "      处置：换更长的 --stability 复测；确认设备未锁屏/未进入低电量模式；必要时重启 WDA"
    fi
fi

echo
echo "[3/4] 运行日志"
LOGS_JSON="$(curl -fsS --max-time 10 "$URL/autodroid/logs?since=0" 2>/dev/null)"
if [ -z "$LOGS_JSON" ]; then
    bad "/autodroid/logs 不可读"
else
    ok "日志接口可用"
    if [ -n "$PYTHON" ]; then
        printf '%s' "$LOGS_JSON" | "$PYTHON" -c "
import json,sys
lines = (json.load(sys.stdin) or {}).get('lines') or []
print(f'      日志 {len(lines)} 行，末尾 5 行：')
for line in lines[-5:]:
    print('        ' + str(line)[:160])
" 2>/dev/null
    fi
fi

echo
echo "[4/4] 完整自检（下发脚本包 → 执行 → 回传）"
if [ -z "$PLATFORM_REPO" ]; then
    warn "未指定 --platform-repo，跳过。手动执行："
    echo "      cd <AutoDroid 平台仓库> && .venv/bin/python -m backend.autojs_export.selftest --url $URL"
else
    if [ -x "$PLATFORM_REPO/.venv/bin/python" ]; then
        PY="$PLATFORM_REPO/.venv/bin/python"
    else
        PY="$PYTHON"
    fi
    if [ -z "$PY" ]; then
        bad "找不到 python，无法运行自检"
    else
        if (cd "$PLATFORM_REPO" && "$PY" -m backend.autojs_export.selftest --url "$URL" --timeout 120); then
            ok "自检通过（会话 + 脚本包 + 步骤执行 + 结果回传）"
        else
            bad "自检未通过，见上方输出；常见原因：脚本包未下发（adapter_js 缺失）、"
            echo "      元素/OCR 动作在原生层失败（看 /autodroid/logs 的 js-error 或步骤 FAIL 行）"
        fi
    fi
fi

echo
echo "==> 自动检查结果: 通过 $pass_count 项 / 失败 $fail_count 项"
echo
echo "需要人工确认的项（脚本无法替代）："
echo "  [ ] 手机重启后，点图标是否还能起 WDA（不能起 → 先连一次 Xcode 重挂 Developer Disk Image，再复测）"
echo "  [ ] 锁屏 / 切到后台 2 分钟后，/autodroid/status 是否仍在"
echo "  [ ] 证书有效期与续期流程（免费账号 7 天：重签 → 重装 → 复跑本脚本）"
echo "  [ ] 真机实跑一条平台用例：平台导出（platform=ios）→ 下发 → 报告中心可见"

exit $([ "$fail_count" -eq 0 ] && echo 0 || echo 1)
