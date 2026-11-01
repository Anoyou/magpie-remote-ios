#!/bin/bash
# 在同一台 runner 上用多台模拟器并行跑 UI 测试（「iOS」工作流的「编译与 UI 测试」用）。
#
# 用法：bash scripts/ci-ui-tests.sh <模拟器 UDID 列表文件>
#   列表文件每行一个 UDID：第 1 行是编译用的那台，其余是它的克隆（simctl clone，见工作流「选择模拟器」）。
# 需要的环境变量：XCTESTRUN（build-for-testing 产出的 .xctestrun）、RESULTS_DIR（结果包与日志的输出目录）。
#
# 做法：
# - 用例按 scripts/ui-test-shards.py 的预计耗时均分给 N 台模拟器（按单个用例分，不按类分，N = UDID 行数）；
# - 每台模拟器一个后台流程：等启动完成 → 用本台最短的用例预热（首屏等待放宽到 240 秒，最多 2 次，
#   通过即算该用例通过）→ 用 test-without-building 跑本台其余用例，失败的用例自动重跑一次；
# - 各台互不等待，全部结束后打印每台的结果，任一台失败则整体失败。
# 为什么不用 xcodebuild 自带的 -parallel-testing-enabled：它按「测试类」分配（本仓库最大的一个类约占总耗时 30%），
# 而且克隆与分配不可控；自己分可以按单个用例均衡，并沿用每台单独预热。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID_FILE="${1:?用法：$0 <UDID 列表文件>}"
: "${XCTESTRUN:?需要 XCTESTRUN}"
: "${RESULTS_DIR:?需要 RESULTS_DIR}"
WORK="${RUNNER_TEMP:-/tmp}/ui-workers"
rm -rf "$WORK" && mkdir -p "$WORK" "$RESULTS_DIR"

# 不用 mapfile：macOS 自带的 bash 3.2 没有。
UDIDS=()
while IFS= read -r line; do [ -n "$line" ] && UDIDS+=("$line"); done < "$UDID_FILE"
N=${#UDIDS[@]}
[ "$N" -ge 1 ] || { echo "::error::没有可用的模拟器"; exit 1; }
SHARDS=(python3 "$ROOT/scripts/ui-test-shards.py" --shards "$N")
TARGET=MagpieRemoteUITests
DEST() { echo "platform=iOS Simulator,id=$1"; }

worker() {
  local i="$1" udid="$2" idx=$(( $1 - 1 ))
  local list="$WORK/tests-$i.txt" note="$WORK/note-$i.txt"
  "${SHARDS[@]}" --index "$idx" --list > "$list"
  local warm
  warm=$("${SHARDS[@]}" --index "$idx" --warmup)
  local t0
  t0=$(date +%s)
  if ! xcrun simctl bootstatus "$udid" -b > "$WORK/bootstatus-$i.log" 2>&1; then
    echo "模拟器启动失败" > "$note"; echo 1 > "$WORK/rc-$i"; return
  fi
  echo "$(date +%T) 模拟器就绪（等了 $(( $(date +%s) - t0 )) 秒）" > "$note"

  local passed=""
  if [ -n "$warm" ]; then
    for try in 1 2; do
      local s
      s=$(date +%s)
      if TEST_RUNNER_MAGPIE_REMOTE_WARMUP_TIMEOUT=240 xcodebuild test-without-building \
          -xctestrun "$XCTESTRUN" -destination "$(DEST "$udid")" \
          -resultBundlePath "$WORK/warmup-$i-$try.xcresult" \
          -parallel-testing-enabled NO -collect-test-diagnostics never \
          "-only-testing:$TARGET/$warm" > "$WORK/warmup-$i-$try.log" 2>&1; then
        passed="$warm"
        mv "$WORK/warmup-$i-$try.xcresult" "$RESULTS_DIR/Warmup-$i.xcresult"
        rm -f "$WORK/warmup-$i-$try.log"
        echo "；$(date +%T) 第 $try 次预热通过（$(( $(date +%s) - s )) 秒，${warm}）" >> "$note"
        break
      fi
      echo "；$(date +%T) 第 $try 次预热未通过（$(( $(date +%s) - s )) 秒）" >> "$note"
    done
  fi

  local args=()
  while IFS= read -r t; do
    [ -n "$t" ] && [ "$t" != "$passed" ] && args+=("-only-testing:$TARGET/$t")
  done < "$list"
  if [ ${#args[@]} -eq 0 ]; then echo 0 > "$WORK/rc-$i"; return; fi
  local s
  s=$(date +%s)
  # 并行时机器更忙：首屏等待放宽到 90 秒（只在 App 启动慢时才会多等）。
  TEST_RUNNER_MAGPIE_REMOTE_WARMUP_TIMEOUT=90 xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" -destination "$(DEST "$udid")" \
    -resultBundlePath "$RESULTS_DIR/UITests-$i.xcresult" \
    -parallel-testing-enabled NO -collect-test-diagnostics never \
    -retry-tests-on-failure -test-iterations 2 \
    "${args[@]}" > "$RESULTS_DIR/test-$i.log" 2>&1
  local rc=$?
  echo "；$(date +%T) 正式测试 ${#args[@]} 个用例 $(( $(date +%s) - s )) 秒，退出码 $rc" >> "$note"
  echo "$rc" > "$WORK/rc-$i"
}

# 机器负载：1 分钟平均负载、可用内存页、换页量（判断台数是否过多）。
load_line() {
  local freep swap load
  freep=$(memory_pressure -Q 2>/dev/null | awk '/percentage/ {print $NF}')
  swap=$(sysctl -n vm.swapusage 2>/dev/null | awk '{print $6}')
  load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
  echo "负载 ${load:-?}，可用内存 ${freep:-?}，已用交换 ${swap:-?}"
}

echo "$N 台模拟器并行（$(date +%T)，$(load_line)）："
"${SHARDS[@]}" --summary
START=$(date +%s)
PIDS=()
for i in $(seq 1 "$N"); do
  worker "$i" "${UDIDS[$((i - 1))]}" &
  PIDS+=($!)
done
# 本步被取消或超时：先结束各台的 xcodebuild，再照常打印结果（结果包由后面的步骤上传）。
stop_all() {
  echo "::warning::UI 测试被中断（$(date +%T)），结束各台测试"
  for p in "${PIDS[@]}"; do pkill -TERM -P "$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; done
  pkill -TERM -f "xcodebuild test-without-building" 2>/dev/null
}
trap 'stop_all' INT TERM

# 每 5 秒看一次是否都结束了，每分钟报一次进度（各台已结束的用例数）。
tick=0
while :; do
  alive=0
  for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
  [ "$alive" = 1 ] || break
  sleep 5
  tick=$((tick + 1))
  [ $((tick % 12)) = 0 ] || continue
  line="$(date +%T) 第 $(( ($(date +%s) - START) / 60 )) 分钟（$(load_line)）："
  for i in $(seq 1 "$N"); do
    done_n=$(grep -cE "^Test Case '.*' (passed|failed)" "$RESULTS_DIR/test-$i.log" 2>/dev/null || true)
    line+=" 第 $i 台 ${done_n:-0}/$(wc -l < "$WORK/tests-$i.txt" | tr -d ' ')"
  done
  echo "$line"
  # 每 3 分钟打印一次最占 CPU 的进程，便于看清时间花在哪（App、XCTest、模拟器后台服务……）。
  if [ $((tick % 36)) = 0 ]; then
    ps -Ao pcpu=,ucomm= -r 2>/dev/null | head -n 6 | sed 's/^/    /'
  fi
done
wait

FAIL=0
for i in $(seq 1 "$N"); do
  rc=$(cat "$WORK/rc-$i" 2>/dev/null || echo 1)
  echo "::group::第 $i 台（退出码 ${rc}）：$(tr -d '\n' < "$WORK/note-$i.txt" 2>/dev/null)"
  if [ -f "$RESULTS_DIR/test-$i.log" ]; then
    if command -v xcbeautify >/dev/null; then
      xcbeautify --renderer github-actions < "$RESULTS_DIR/test-$i.log" || true
    else
      grep -E "^Test Case|error:|Executed" "$RESULTS_DIR/test-$i.log" || true
    fi
  fi
  for f in "$WORK"/warmup-"$i"-*.log; do
    [ -f "$f" ] && { echo "-- 预热日志 $(basename "$f")（未通过）"; grep -E "error:|failed|Failing" "$f" | head -n 20; }
  done
  echo "::endgroup::"
  [ "$rc" = 0 ] || FAIL=1
done
for i in $(seq 1 "$N"); do echo "第 $i 台：$(tr -d '\n' < "$WORK/note-$i.txt" 2>/dev/null)"; done | tee "$RESULTS_DIR/workers.txt"
cp "$WORK"/warmup-*.log "$WORK"/bootstatus-*.log "$RESULTS_DIR/" 2>/dev/null || true
echo "UI 测试共用时 $(( $(date +%s) - START )) 秒"
[ "$FAIL" = 0 ] || { echo "::error::有模拟器上的 UI 测试未通过（见上方各台日志与「打印失败的断言」）"; exit 1; }
