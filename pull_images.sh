#!/bin/zsh
# =============================================================
# WeKnora 镜像拉取工具（适用于网络受限环境，走代理 + 官方 Docker Hub）
#
# 用法:
#   ./pull_images.sh                          # 默认: 代理 127.0.0.1:7897, 架构 arm64, 版本 latest
#   ./pull_images.sh <代理地址> <架构> <版本>    # 例: ./pull_images.sh http://127.0.0.1:7897 amd64 v0.7.2
#   环境变量: PULL_PROXY / PULL_ARCH / WEKNORA_VERSION 优先级高于参数
#
# 依赖: docker、skopeo (brew install skopeo / apt install skopeo)
#
# 原理: skopeo 走宿主机网络 + 代理从官方源下载镜像为 tar，
#       再 docker load 导入——绕开 Docker 引擎虚拟机网络层的限制。
#       已存在的镜像自动跳过；单次下载 900 秒超时，失败自动重试 4 次。
# =============================================================
set -u

PROXY="${PULL_PROXY:-${1:-http://127.0.0.1:7897}}"
ARCH="${PULL_ARCH:-${2:-$(uname -m | sed 's/arm64/arm64/;s/x86_64/amd64/')}}"
VERSION="${WEKNORA_VERSION:-latest}"

export HTTPS_PROXY="$PROXY" HTTP_PROXY="$PROXY"

# ---- 镜像清单（${VERSION} 仅作用于 weknora 官方镜像）----
IMAGES=(
  "busybox:1.36"
  "redis:7-alpine"
  "searxng/searxng:latest"
  "paradedb/paradedb:v0.22.2-pg17"
  "wechatopenai/weknora-ui:${VERSION}"
  "wechatopenai/weknora-app:${VERSION}"
  "wechatopenai/weknora-sandbox:${VERSION}"
  "wechatopenai/weknora-docreader:${VERSION}"
)

echo "代理: $PROXY | 架构: $ARCH | 版本: $VERSION"

ok=0; fail=0
for img in "${IMAGES[@]}"; do
  name="${img%%:*}"; tag="${img##*:}"
  if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "$img"; then
    echo "[skip] $img 已存在"
    continue
  fi
  tarf="/tmp/skopeo_$(echo "$img" | tr '/:' '__').tar"
  done_ok=0
  for attempt in 1 2 3 4; do
    echo "[try$attempt] $img ..."
    rm -f "$tarf"
    if timeout 900 skopeo copy --override-os linux --override-arch "$ARCH" \
        "docker://$img" "docker-archive:$tarf:$name:$tag"; then
      if docker load -i "$tarf"; then
        rm -f "$tarf"; echo "[done] $img"; done_ok=1; ok=$((ok+1)); break
      else
        echo "[FAIL-load] $img 第${attempt}次"
      fi
    else
      echo "[RETRY] $img 第${attempt}次失败/超时，3秒后重试"; sleep 3
    fi
  done
  [ $done_ok -eq 0 ] && { echo "[GIVE-UP] $img"; fail=$((fail+1)); }
  rm -f "$tarf"
done

echo "ALL_DONE 成功:$ok 失败:$fail"
[ $fail -eq 0 ]
