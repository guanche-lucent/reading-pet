#!/bin/bash
# 读书养宠 · 只检查配置（会调用一次模型做最小连通性测试，花费可忽略）
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="/Users/chen/Documents/projects/agent-blueprint"

if [ ! -f "$DIR/.env" ]; then
  echo "❌ 缺少 $DIR/.env（先 cp .env.example .env 并填入 API Key）"; exit 1
fi

# 先加载本项目配置（环境变量优先于引擎自带的 .env）
set -a
. "$DIR/.env"
set +a

cd "$ENGINE"
.venv/bin/python - <<'PY'
import os, re
from dotenv import load_dotenv
# 引擎自带的 .env 只是兜底：已存在的环境变量（来自本项目 .env）优先
load_dotenv("/Users/chen/Documents/projects/agent-blueprint/.env", override=False)

key = os.environ.get("ANTHROPIC_API_KEY", "")
mask = lambda v: (v[:6] + "*" * max(len(v) - 7, 0) + v[-1]) if len(v) >= 8 else "<空>"
print(f"  钥匙     : {mask(key)}  长度 {len(key)}")
print(f"  网关地址 : {os.environ.get('ANTHROPIC_BASE_URL') or '<未设置>'}")
print(f"  模型     : {os.environ.get('MODEL_ID') or '<未设置>'}")
print(f"  超时     : {os.environ.get('ANTHROPIC_TIMEOUT', '120')} 秒")

from blueprint.llm import AnthropicRunner, Budget
try:
    r = AnthropicRunner(budget=Budget(max_calls=1, max_tokens=2000))
    out = r.complete("配置自检", "只输出一个 JSON 对象。", '输出 {"ok": true, "msg": "可用"}',
                     {"type": "object",
                      "properties": {"ok": {"type": "boolean"}, "msg": {"type": "string"}},
                      "required": ["ok", "msg"]})
    print(f"  连通性   : ✅ 通过 → {out}")
except Exception as exc:
    print(f"  连通性   : ❌ 失败 → {re.sub(r'sk-[A-Za-z0-9_-]{4,}', 'sk-****', str(exc))[:200]}")
    raise SystemExit(1)
PY
