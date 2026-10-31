#!/bin/bash
# 模拟器 dyld 共享缓存的打包 / 恢复（「iOS」与「模拟器缓存预热」工作流用）。
#
# 背景：xcode-27 runner 的镜像里没有预先生成模拟器运行时的 dyld 共享缓存。第一次调用 simctl 时
# CoreSimulatorService 会为每个 iOS 运行时生成缓存（/Library/Developer/CoreSimulator/Caches/dyld），
# 3 核机器上要好几分钟，期间编译、模拟器启动和 UI 测试都会被拖慢数倍。把生成好的缓存存进
# actions/cache，下次在第一次调用 simctl 之前放回去，就能跳过这段时间。缓存不对（镜像或运行时变了）
# 时 CoreSimulator 会自己重新生成，最多只是白下载一次。
#
# 用法：
#   ci-sim-dyld-cache.sh key              打印缓存 key（镜像版本 + macOS build + Xcode build）
#   ci-sim-dyld-cache.sh restore <目录>   <目录>/dyld.tar 存在则解压回系统目录（必须在第一次调用 simctl 之前）
#   ci-sim-dyld-cache.sh pack <目录>      等缓存生成完，把系统目录打包成 <目录>/dyld.tar；生成未完成则不打包（退出码 0）
set -uo pipefail

SYS_DIR=/Library/Developer/CoreSimulator/Caches
CMD="${1:-}"
DIR="${2:-}"

case "$CMD" in
  key)
    XCODE_BUILD=$(xcodebuild -version 2>/dev/null | awk '/Build version/ {print $3}')
    echo "sim-dyld-v1-${ImageOS:-macos}-${ImageVersion:-unknown}-$(sw_vers -buildVersion)-xcode${XCODE_BUILD:-unknown}"
    ;;
  restore)
    if [ -f "$DIR/dyld.tar" ]; then
      START=$(date +%s)
      sudo mkdir -p "$SYS_DIR"
      sudo tar -xpf "$DIR/dyld.tar" -C "$SYS_DIR" && echo "已恢复模拟器 dyld 缓存（$(du -sh "$DIR/dyld.tar" | cut -f1)，$(( $(date +%s) - START )) 秒）："
      ls "$SYS_DIR/dyld"/*/ 2>/dev/null || true
      rm -f "$DIR/dyld.tar"
    else
      echo "没有可用的模拟器 dyld 缓存，本次由 CoreSimulator 现场生成"
    fi
    ;;
  pack)
    mkdir -p "$DIR"
    # 等后台的 update_dyld_sim_shared_cache 全部结束（最多 10 分钟），没结束就不打包，免得存进半成品。
    for _ in $(seq 1 120); do
      pgrep -f update_dyld_sim_shared_cache >/dev/null || break
      sleep 5
    done
    if pgrep -f update_dyld_sim_shared_cache >/dev/null; then
      echo "::warning::模拟器 dyld 缓存仍在生成，跳过保存"
      exit 0
    fi
    if [ ! -d "$SYS_DIR/dyld" ]; then echo "没有 $SYS_DIR/dyld，跳过保存"; exit 0; fi
    sudo tar -cf "$DIR/dyld.tar" -C "$SYS_DIR" dyld
    sudo chown "$(id -u)" "$DIR/dyld.tar"
    echo "已打包模拟器 dyld 缓存：$(du -sh "$DIR/dyld.tar" | cut -f1)"
    sudo du -sh "$SYS_DIR/dyld"/*/* 2>/dev/null || true
    echo "packed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    ;;
  *)
    echo "用法：$0 key | restore <目录> | pack <目录>" >&2
    exit 2
    ;;
esac
