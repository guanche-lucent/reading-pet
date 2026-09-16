#!/bin/bash
# 读书养宠 · 一键跑方案
#
# 用法：
#   ./跑方案.sh                → 产物/v3-新一版/ ，并把方案正文拷进 docs/方案-v3-新一版.md
#   ./跑方案.sh v4-改过措辞     → 名字自己起
#   ./跑方案.sh v5-续跑 --resume → 额外参数原样传给引擎
#
# 目录约定：
#   docs/   给人看的文档（点子、方案正文、问题清单）——只有这里才是"正式文档"
#   产物/   引擎的机器产物（plan.json、stages 缓存）——用于 --resume，不给人看
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="/Users/chen/Documents/projects/agent-blueprint"
OUT="${1:-v3-新一版}"

if [ ! -f "$DIR/.env" ]; then
  echo "❌ 缺少配置文件：$DIR/.env"
  echo "   请执行： cp \"$DIR/.env.example\" \"$DIR/.env\"  然后填入自己的 API Key"
  exit 1
fi

# 1) 加载「本项目」配置（环境变量优先于引擎自带的 .env，所以项目之间互不影响）
set -a
. "$DIR/.env"
set +a

# 2) 调引擎；机器产物写进本项目的 产物/
cd "$ENGINE"
echo "──────────────────────────────────────────────"
echo "项目    ：读书养宠"
echo "点子    ：$DIR/docs/01-点子.md"
echo "模型    ：${MODEL_ID}"
echo "网关    ：${ANTHROPIC_BASE_URL}"
echo "超时    ：${ANTHROPIC_TIMEOUT:-120} 秒"
echo "机器产物：$DIR/产物/$OUT"
echo "正式文档：$DIR/docs/方案-$OUT.md"
echo "──────────────────────────────────────────────"

shift || true
.venv/bin/python -m blueprint plan "$DIR/docs/01-点子.md" -o "$DIR/产物/$OUT" "$@"

# 3) 把方案正文拷进文档区（人类唯一需要看的地方）
mkdir -p "$DIR/docs"
cp "$DIR/产物/$OUT/方案.md" "$DIR/docs/方案-$OUT.md"
echo
echo "✅ 完成："
echo "   文档 → $DIR/docs/方案-$OUT.md"
echo "   产物 → $DIR/产物/$OUT/（plan.json、stages/）"
