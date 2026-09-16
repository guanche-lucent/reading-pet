# 读书养宠 · 数据模型与 API 契约

> 状态：**设计稿，待评审**（未经过独立模型审稿；本文只有当前 AI 自查）
> 依据：`方案-v3.1-人工修订.md`（Step 1–4）+ `01-点子.md` 的已确认决策与指标口径
> 范围：**只出数据模型与 API 契约，不写产品代码**。文档、代码、数据库迁移文件都没生成。
> 关系人看的图文形态（任务卡页面、宠物房间、删除入口）**不在本文范围**，属 UI 原型任务。
> 生成日期：2026-09-16

---

## 1. 本文从 v3.1 继承了哪些硬约束

| 来源条款 | 落到本文 |
|---|---|
| 9 个工具（含唯一外发出口 `call_model_service`） | 每个工具对应哪些表、哪些端点（见 §3.4 映射表） |
| 外发前必须显式确认，确认一次覆盖整本 | `book_consents` 表 + `POST /books/{id}/consent` + `NEED_CONSENT` 错误码 |
| 幂等键 = book_id + 页范围 + 生成类型 | `gen_idempotency` 表 + 唯一约束（同一页只生成一次、不重复计费） |
| PDF 原文与解析全文 7 天到期；应用侧判断为主、存储生命周期兜底 | `books.originals_expire_at` + 所有读取接口先校验到期 |
| 长期只保留：任务卡、复述、进度、已掌握/易忘概念、宠物状态、审计 | 见 §2.5 保留期矩阵 |
| 删除后**前台立即不可见** | `delete_audit.frontend_hidden_at` + 删除接口同步置不可见 |
| 判定「存疑」不计完成、不惩罚，需定期人工复核 | `judgements.result=uncertain` + `manual_review_queue` |
| 指标口径（上传日起算 7 天、完成=通过、分母含存疑不含系统错误） | `retellings.is_system_error` + 视图 `v_kpi_main` / `v_kpi_guard` + §4 取数 SQL |
| 单本上限 300 页 / 20 万字；只收文本型 PDF | 上传校验 + 错误码 `PAGE_LIMIT_EXCEEDED` / `NOT_TEXT_PDF` |
| 跨账号越权一律拒绝并写审计 | 所有查询强制 `account_id` 过滤 + `outbound_audit` 之外的 `access_audit` |

**未定项（本文沿用"待确认"，不自行决定）**：数据库产品（默认 PostgreSQL）、对象存储、账号方式（邮箱 / 第三方）、模型厂商与成本上限、时延目标、宠物素材数量与标签表。

---

## 2. 数据模型

### 2.1 实体关系概览

```
accounts ─┬─ books ─┬─ source_blocks ──── chapters/concepts/terms（随原文 7 天到期）
          │         ├─ book_consents（外发确认，覆盖整本）
          │         ├─ keypoints（★长期保留：判定的唯一依据）
          │         ├─ task_cards ── retellings ── judgements ── manual_review_queue
          │         ├─ reading_progress
          │         └─ memory_concepts（已掌握 / 易忘）
          ├─ pet_state（性格 / 房间 / 预置素材 key）
          ├─ delete_audit（删除请求与生效时间）
          └─ event_log（埋点，支撑两个 KPI）

job_queue（worker：解析 / 拆书 / 逐页出题）
gen_idempotency（book_id + 页范围 + 生成类型，唯一）
outbound_audit（每次外发的独立审计）
```

### 2.2 状态机

**书 `books.status`**

| 状态 | 含义 | 允许的下一步 |
|---|---|---|
| `uploaded` | 已上传，待校验 | 校验通过 → `validating_done`；失败 → `rejected` |
| `rejected` | 不合格（非文本型 PDF / 超页数 / 扫描件） | 重新上传 |
| `parsing` | 后台解析中（可退出，回来再看） | 成功 → `ready`；失败 → `failed` |
| `ready` | 已解析、可出卡 | 到期 → `expired`；用户删除 → `deleted` |
| `failed` | 解析失败，可重试 | 重试 → `parsing` |
| `expired` | 原文满 7 天，已不可读、不参与出题与判定 | 用户重新上传 → 新 `book_id` |
| `deleted` | 用户已删除，前台不可见 | — |

**任务卡 `task_cards.status`**：`available` → `opened` → `submitted` → `judged`（判定结果在 `judgements.result`）

**后台任务 `job_queue.status`**：`pending` → `running` → `succeeded` / `failed` / `timeout`（超时或失败可续跑，**从最后一个完成页继续，不重跑已完成页**）

**判定 `judgements.result`**：`pass` / `fail` / `uncertain`（三态；`uncertain` 不计完成、不惩罚，但进人工复核队列）

### 2.3 核心表 DDL（PostgreSQL）

```sql
-- 账号（登录方式待确认，先只存主体）
CREATE TABLE accounts (
  account_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  login_type      TEXT NOT NULL,               -- email | third_party（待确认）
  login_id        TEXT NOT NULL,
  timezone        TEXT NOT NULL DEFAULT 'Asia/Shanghai',  -- 指标口径要按用户本地日切分
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  status          TEXT NOT NULL DEFAULT 'active',
  UNIQUE (login_type, login_id)
);

-- 书（原文与解析全文 7 天到期；到期判断主体是应用服务）
CREATE TABLE books (
  book_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id          UUID NOT NULL REFERENCES accounts(account_id),
  title               TEXT,
  file_object_key     TEXT,                    -- 对象存储里的原文
  file_sha256         TEXT,
  page_count          INT,
  char_count          INT,
  status              TEXT NOT NULL,           -- 见 §2.2
  reject_reason       TEXT,                    -- NOT_TEXT_PDF | PAGE_LIMIT_EXCEEDED | ...
  uploaded_date       DATE NOT NULL,           -- ★指标口径：计时起点 = 上传日
  originals_expire_at TIMESTAMPTZ NOT NULL,    -- uploaded_at + 7 天
  frontend_hidden_at  TIMESTAMPTZ,             -- 用户删除后立即写入
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error          TEXT
);
CREATE INDEX idx_books_account ON books(account_id, status);
CREATE INDEX idx_books_expire  ON books(originals_expire_at) WHERE frontend_hidden_at IS NULL;

-- 外发确认（一次确认覆盖整本；已确认的书不再重复弹窗，但每次外发仍写审计）
CREATE TABLE book_consents (
  consent_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id      UUID NOT NULL REFERENCES accounts(account_id),
  book_id         UUID NOT NULL REFERENCES books(book_id),
  scope           TEXT NOT NULL DEFAULT 'entire_book',
  consent_text_version TEXT NOT NULL,          -- 用户同意的是哪一版说明文案
  confirmed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at      TIMESTAMPTZ
);
CREATE UNIQUE INDEX uq_consent_active ON book_consents(book_id) WHERE revoked_at IS NULL;

-- 解析块（随原文 7 天到期删除）
CREATE TABLE source_blocks (
  block_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id      UUID NOT NULL REFERENCES books(book_id),
  page_no      INT NOT NULL,
  seq_in_page  INT NOT NULL,
  heading_path TEXT,
  text         TEXT NOT NULL,
  block_type   TEXT NOT NULL DEFAULT 'paragraph',  -- paragraph | table | image_placeholder
  UNIQUE (book_id, page_no, seq_in_page)
);

-- 知识库：章节 / 概念 / 规则 / 术语（解析产物，随原文到期）
CREATE TABLE chapters (
  chapter_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id UUID NOT NULL REFERENCES books(book_id),
  parent_id UUID REFERENCES chapters(chapter_id),
  title TEXT, page_start INT, page_end INT, order_no INT
);
CREATE TABLE concepts (
  concept_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id UUID NOT NULL REFERENCES books(book_id),
  kind TEXT NOT NULL,                          -- concept | rule | term
  name TEXT NOT NULL, summary TEXT,
  source_block_ids UUID[] NOT NULL DEFAULT '{}',   -- 必须可回溯到块
  expires_at TIMESTAMPTZ NOT NULL
);

-- ★关键点：判定的唯一依据，长期保留（不随原文 7 天删除）
CREATE TABLE keypoints (
  keypoint_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  book_id      UUID NOT NULL REFERENCES books(book_id),
  page_ref     INT NOT NULL,                   -- 只留页码锚点，不留原文
  text         TEXT NOT NULL,                  -- 关键点表述（判定依据）
  from_chapter UUID REFERENCES chapters(chapter_id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_keypoints_book_page ON keypoints(book_id, page_ref);

-- 生成幂等（同一页只生成一次，不重复计费）
CREATE TABLE gen_idempotency (
  book_id     UUID NOT NULL REFERENCES books(book_id),
  page_start  INT NOT NULL,
  page_end    INT NOT NULL,
  gen_type    TEXT NOT NULL,                   -- extract | card
  first_generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  output_ref  TEXT,                            -- 产出的 keypoint 集合或 card_id
  hit_count   INT NOT NULL DEFAULT 0,          -- 命中次数（重复生成次数应恒为 0）
  PRIMARY KEY (book_id, page_start, page_end, gen_type)
);

-- 任务卡（长期保留）
CREATE TABLE task_cards (
  card_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id     UUID NOT NULL REFERENCES accounts(account_id),
  book_id        UUID NOT NULL REFERENCES books(book_id),
  card_date      DATE NOT NULL,                -- 每天一张
  page_start     INT NOT NULL,
  page_end       INT NOT NULL,
  goal           TEXT NOT NULL,                -- 一个明确行动
  question       TEXT NOT NULL,                -- 一道开放式复述题
  keypoint_ids   UUID[] NOT NULL,              -- 本题所依据的关键点
  excerpt_md     TEXT,                         -- 当段节选（到期后置空）
  status         TEXT NOT NULL DEFAULT 'available',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, book_id, card_date)
);
CREATE INDEX idx_cards_account_date ON task_cards(account_id, card_date DESC);

-- 复述提交（每次提交一条；重试也算新的一条）
CREATE TABLE retellings (
  retelling_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  card_id         UUID NOT NULL REFERENCES task_cards(card_id),
  account_id      UUID NOT NULL REFERENCES accounts(account_id),
  attempt_no      INT NOT NULL,
  text            TEXT NOT NULL,
  submitted_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_system_error BOOLEAN NOT NULL DEFAULT FALSE,  -- ★时长/结构非法/外发被拒等，不进护栏分母
  system_error_code TEXT,
  UNIQUE (card_id, attempt_no)
);
CREATE INDEX idx_retellings_card ON retellings(card_id, submitted_at DESC);

-- 判定（同一复述可因重试有多次；「最后一次」才计入指标）
CREATE TABLE judgements (
  judgement_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  retelling_id  UUID NOT NULL REFERENCES retellings(retelling_id),
  card_id       UUID NOT NULL REFERENCES task_cards(card_id),
  result        TEXT NOT NULL,                 -- pass | fail | uncertain
  hit_keypoint_ids UUID[] NOT NULL DEFAULT '{}',   -- 只可引用已有 keypoint，不得新造
  reason        TEXT,
  model_name    TEXT, latency_ms INT, tokens_in INT, tokens_out INT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_judgements_card ON judgements(card_id, created_at DESC);

-- 存疑人工复核队列
CREATE TABLE manual_review_queue (
  review_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  judgement_id UUID NOT NULL REFERENCES judgements(judgement_id),
  status       TEXT NOT NULL DEFAULT 'pending',   -- pending | reviewed
  reviewer     TEXT, decided_result TEXT, note TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  reviewed_at  TIMESTAMPTZ,
  UNIQUE (judgement_id)
);

-- 阅读进度（长期保留）
CREATE TABLE reading_progress (
  account_id      UUID NOT NULL REFERENCES accounts(account_id),
  book_id         UUID NOT NULL REFERENCES books(book_id),
  last_card_id    UUID REFERENCES task_cards(card_id),
  last_page       INT,
  cards_completed INT NOT NULL DEFAULT 0,      -- 判定通过才算完成
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, book_id)
);

-- 记忆：已掌握 / 易忘概念（长期保留）
CREATE TABLE memory_concepts (
  account_id     UUID NOT NULL REFERENCES accounts(account_id),
  book_id        UUID NOT NULL REFERENCES books(book_id),
  keypoint_id    UUID REFERENCES keypoints(keypoint_id),
  concept_name   TEXT NOT NULL,
  state          TEXT NOT NULL,                -- mastered | forgotten | stuck
  evidence_count INT NOT NULL DEFAULT 0,
  miss_count     INT NOT NULL DEFAULT 0,
  last_seen_at   TIMESTAMPTZ,
  PRIMARY KEY (account_id, book_id, concept_name)
);

-- 宠物状态（长期保留；素材只用预置静态图，不实时生成）
CREATE TABLE pet_state (
  account_id     UUID PRIMARY KEY REFERENCES accounts(account_id),
  level          INT NOT NULL DEFAULT 1,
  persona_tags   TEXT[] NOT NULL DEFAULT '{}', -- 由书本内容标签累积
  room_theme_id  TEXT,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 内容标签 → 宠物性格 / 房间映射（配置表，随版本走）
CREATE TABLE pet_asset_map (
  tag           TEXT NOT NULL,                 -- 书本内容标签
  persona_delta TEXT,                          -- 命中的性格标签
  room_theme_id TEXT,
  asset_key     TEXT NOT NULL,                 -- 预置静态素材 key
  version       TEXT NOT NULL,
  PRIMARY KEY (tag, version)
);

-- 外发审计（唯一出口 call_model_service 每次写一条；不记原文）
CREATE TABLE outbound_audit (
  audit_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   UUID NOT NULL,
  book_id      UUID,
  consent_id   UUID REFERENCES book_consents(consent_id),
  tool_name    TEXT NOT NULL,                  -- extract_book_knowledge | build_daily_task_card | judge_retelling
  model_name   TEXT NOT NULL,
  scope_refs   TEXT NOT NULL,                  -- 页/段 id 列表，不含正文
  purpose      TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_outbound_book ON outbound_audit(book_id, created_at DESC);

-- 删除审计（前台立即不可见 + 后台清除进度）
CREATE TABLE delete_audit (
  delete_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id         UUID NOT NULL,
  scope              TEXT NOT NULL,            -- book | account
  target_id          UUID,
  confirm_token_hash TEXT NOT NULL,            -- 只存凭据哈希，不存凭据原文
  frontend_hidden_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  purge_status       TEXT NOT NULL DEFAULT 'pending',  -- pending | purging | done | failed
  purged_at          TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 后台任务（轻量任务表；不引入消息队列）
CREATE TABLE job_queue (
  job_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kind         TEXT NOT NULL,                  -- parse | extract | card
  book_id      UUID NOT NULL,
  page_start   INT, page_end INT,
  status       TEXT NOT NULL DEFAULT 'pending',
  attempts     INT NOT NULL DEFAULT 0,
  last_error   TEXT, last_error_code TEXT,
  lease_until  TIMESTAMPTZ,                    -- 防重复执行
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_jobs_pick ON job_queue(status, created_at) WHERE status = 'pending';

-- 埋点（支撑两个 KPI 与失败率）
CREATE TABLE event_log (
  event_id   BIGSERIAL PRIMARY KEY,
  event_name TEXT NOT NULL,                    -- book_uploaded | card_opened | retelling_submitted | ...
  account_id UUID,
  book_id    UUID, card_id UUID,
  props      JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_events_name_time ON event_log(event_name, created_at DESC);
```

### 2.4 指标视图（口径直接落库，不靠人工统计）

```sql
-- 主要指标：上传日起 7 天内「完成」≥3 张卡的用户
CREATE VIEW v_kpi_main AS
WITH first_upload AS (               -- 计时起点 = 上传日
  SELECT account_id, MIN(uploaded_date) AS start_date
  FROM books WHERE status <> 'rejected' GROUP BY account_id
),
last_judge AS (                      -- 同一张卡以「最后一次判定」为准
  SELECT r.card_id, j.result,
         row_number() OVER (PARTITION BY r.card_id ORDER BY j.created_at DESC) AS rn
  FROM retellings r JOIN judgements j USING (retelling_id)
  WHERE r.is_system_error = FALSE
),
completed AS (                       -- 「完成」= 复述已提交且判定通过
  SELECT DISTINCT c.account_id, c.card_id
  FROM task_cards c
  JOIN last_judge l ON l.card_id = c.card_id AND l.rn = 1 AND l.result = 'pass'
  JOIN first_upload f ON f.account_id = c.account_id
  WHERE c.card_date BETWEEN f.start_date AND f.start_date + 6
)
SELECT a.account_id,
       COUNT(DISTINCT m.card_id) AS cards_completed_in_7d,
       COUNT(DISTINCT m.card_id) >= 3 AS is_main_kpi_pass
FROM accounts a LEFT JOIN completed m USING (account_id)
WHERE a.status = 'active'
GROUP BY a.account_id;

-- 护栏指标：复述有效性（分母含「存疑」、不含系统错误；同卡按最后一次）
CREATE VIEW v_kpi_guard AS
SELECT COUNT(*) FILTER (WHERE result = 'pass')::numeric / NULLIF(COUNT(*), 0) AS retelling_pass_rate,
       COUNT(*) AS denominator
FROM (
  SELECT DISTINCT ON (r.card_id) j.result
  FROM retellings r JOIN judgements j USING (retelling_id)
  WHERE r.is_system_error = FALSE
  ORDER BY r.card_id, j.created_at DESC
) t;
```

### 2.5 保留期矩阵（谁到期删、谁长期留）

| 数据 | 保留 | 到期后行为 |
|---|---|---|
| PDF 原文（对象存储） | **7 天** | 应用侧先判到期 → 不可读；存储生命周期兜底删除 |
| `source_blocks` / `chapters` / `concepts` | **7 天** | 物理删除 |
| `task_cards.excerpt_md`（当段节选） | **7 天** | 字段置空，卡片本身保留 |
| `keypoints` | **长期** | 只留页码锚点 + 关键点表述（判定的唯一依据） |
| `task_cards` / `retellings` / `judgements` | **长期** | 保留 |
| `reading_progress` / `memory_concepts` / `pet_state` | **长期** | 保留 |
| `outbound_audit` / `delete_audit` / `gen_idempotency` | **长期** | 保留（审计与幂等） |
| `event_log` | 长期（可按季度归档） | 保留 |
| 模型请求/响应全文 | **不留** | 只留脱敏摘要（`judgements` 里的 model/latency/tokens） |

### 2.6 9 个工具 ↔ 表 ↔ 端点 对照（保证双向闭合）

| 工具（v3.1） | 主要读写表 | 对应端点 | 权限 |
|---|---|---|---|
| `parse_book_pdf` | `books`、`source_blocks`、`job_queue` | `POST /books`（后台跑） | allow（本地解析，不外发） |
| `get_book_knowledge` | `source_blocks`、`chapters`、`concepts`、`keypoints` | `GET /books/{id}/knowledge` | allow |
| `extract_book_knowledge` | `keypoints`、`concepts`、`gen_idempotency` | 由 `job_queue` 驱动（无公开端点） | **ask**（经 `call_model_service`） |
| `build_daily_task_card` | `task_cards`、`gen_idempotency` | `GET /today` | **ask** |
| `judge_retelling` | `retellings`、`judgements`、`manual_review_queue` | `POST /cards/{id}/retelling` | **ask** |
| `call_model_service` | `outbound_audit`、`book_consents` | 内部（无公开端点） | **ask** |
| `update_pet_state` | `pet_state`、`pet_asset_map` | `GET /pet`（写入随判定事务） | allow |
| `sync_reading_memory` | `reading_progress`、`memory_concepts` | `GET /memory`（写入随判定事务） | allow |
| `delete_reading_data` | `delete_audit` + 全表清理 | `DELETE /books/{id}`、`DELETE /accounts/me` | **ask** |

---

## 3. API 契约

### 3.1 通用约定

| 项 | 约定 |
|---|---|
| 前缀 | `/api/v1` |
| 认证 | `Authorization: Bearer <token>`（账号登录方式待确认，先按此预留） |
| 时间 | 全部 ISO-8601 UTC；**按天切分**用 `accounts.timezone` |
| 幂等 | 写接口支持 `Idempotency-Key` 头；生成类另用 `gen_idempotency` 兜底 |
| 分页 | `?cursor=&limit=`（默认 20，上限 100） |
| 错误体 | `{"error":{"code":"...","message":"人话说明","details":{...},"trace_id":"..."}}` |
| 权限语义 | `allow` 直接执行；`ask` 需有效 `consent`，否则返回 `NEED_CONSENT`；`deny` 直接拒绝并写审计 |
| 归属校验 | 所有请求以 `account_id + book_id` 双因子校验；跨账号一律 `CROSS_ACCOUNT_DENIED` + 审计 |

### 3.2 错误码表

| HTTP | code | 含义 / 前端动作 |
|---|---|---|
| 400 | `NOT_TEXT_PDF` | 扫描件或无法提取文本：明确告知不支持，不进入生成 |
| 400 | `UNSUPPORTED_FILE_TYPE` | 非 PDF（如 EPUB/DOCX）：说明本期只支持文本型 PDF |
| 400 | `FILE_TOO_LARGE` / `PAGE_LIMIT_EXCEEDED` | 超 300 页 / 20 万字：说明上限 |
| 402? → 409 | `CONSENT_REVOKED` | 用户撤回了外发确认 |
| 403 | `NEED_CONSENT` | **需要先确认外发**，返回 `consent_required_url`；不降级、不静默跳过 |
| 403 | `CROSS_ACCOUNT_DENIED` | 越权访问，拒绝并写审计 |
| 410 | `BOOK_EXPIRED` | 原文已满 7 天不可读；提示需重新上传（生成新 `book_id`） |
| 404 | `BOOK_DELETED` | 已删除，前台不可见 |
| 409 | `DELETE_CONFIRM_REQUIRED` | 删除必须带确认凭据 |
| 422 | `MODEL_OUTPUT_INVALID` | 模型输出结构非法（已做一次修复重试） |
| 429 | `MODEL_RATE_LIMITED` | 上游限流，可稍后重试 |
| 503 | `MODEL_UNAVAILABLE` | 模型服务不可用：前台说明真实原因，**不用模板冒充结果** |
| 504 | `JOB_TIMEOUT` | 解析/出题超时，可续跑（从最后完成页继续） |

### 3.3 端点清单

#### 上传与书

**`POST /api/v1/books`** — 上传 PDF（multipart，字段 `file`）
- 校验顺序：真实 MIME → 大小 → 页数/字数 → 能否提取文本（提取率过低判扫描件）
- 201：

```json
{
  "book_id": "b_1f8c...",
  "status": "parsing",
  "page_count": 212,
  "char_count": 138400,
  "originals_expire_at": "2026-09-23T10:12:00Z",
  "consent_required": true
}
```

**`GET /api/v1/books/{book_id}`** — 元数据 + 状态 + 到期 + 确认状态
**`GET /api/v1/books?status=ready`** — 我的书列表（游标分页）
**`POST /api/v1/books/{book_id}/consent`** — 确认外发（覆盖整本）

```json
{ "scope": "entire_book", "consent_text_version": "v1-20260916" }
→ 201 { "consent_id": "c_...", "confirmed_at": "2026-09-16T10:15:00Z", "scope": "entire_book" }
```

**`GET /api/v1/books/{book_id}/knowledge?page_start=12&page_end=14`** — 按需取知识（不外发、不计数）

#### 每日阅读与复述

**`GET /api/v1/today?book_id=b_...`** — 取今天的任务卡；没有则入队生成并返回 `status: generating`（异步，前端轮询或稍后再开）
- 200：

```json
{
  "card_id": "card_...",
  "card_date": "2026-09-16",
  "page_range": [12, 14],
  "goal": "读完这段，找出作者认为习惯容易失败的一个原因",
  "question": "不用照抄原文：你会怎样把这个原因讲给朋友听？",
  "excerpt_md": "……",
  "status": "available"
}
```

**`POST /api/v1/cards/{card_id}/retelling`** — 提交复述
```json
{ "text": "作者觉得习惯失败是因为环境提示不够明显……" }
```
- 200：

```json
{
  "card_id": "card_...",
  "judgement": "pass",
  "hit_keypoints": [{ "keypoint_id": "kp_...", "text": "环境提示不足" }],
  "feedback": "我听见你抓住了「环境提示」这一点。",
  "pet_change": { "level": 2, "persona_tags_added": ["观察力"], "room_theme_id": "study_nook", "asset_key": "pet_lv2_study" },
  "progress": { "cards_completed": 3, "kpi_main_in_7d": true }
}
```
- `judgement` 三态：`pass`（计完成）/ `fail`（可重交）/ `uncertain`（**不计失败、不惩罚**，进人工复核）
- 系统错误（超时、结构非法、外发被拒）→ 4xx/5xx + `retellings.is_system_error = true`，**不进护栏分母**

**`GET /api/v1/cards/{card_id}`** — 单卡详情（含历史提交与判定）

#### 宠物与记忆

**`GET /api/v1/pet`** → `pet_state` + 当前素材 key（只用预置静态素材）
**`GET /api/v1/memory?book_id=b_...`** → 进度、已掌握、易忘、卡点

#### 删除（必须显式确认）

**`POST /api/v1/books/{book_id}/delete-request`** → 返回一次性确认凭据 `confirm_token`
**`DELETE /api/v1/books/{book_id}`**（头 `X-Confirm-Token`）→ 200：

```json
{ "book_id": "b_...", "frontend_hidden_at": "2026-09-16T10:30:12Z", "purge_status": "pending" }
```
- **同步生效**：`frontend_hidden_at` 一写入，所有读取接口立即返回 `BOOK_DELETED`
- `DELETE /api/v1/accounts/me` 同理（范围=账号）

#### 内部（worker 与运维，不对普通用户开放）

| 端点 | 用途 |
|---|---|
| `POST /internal/jobs/parse` / `extract` / `card` | 由 worker 拉取并执行；带租约防重复 |
| `POST /internal/jobs/{job_id}/retry` | 失败续跑（从最后完成页继续） |
| `GET /ops/reviews?status=pending` / `POST /ops/reviews/{id}` | 存疑样本人工复核 |
| `GET /ops/metrics` | 返回 `v_kpi_main` / `v_kpi_guard` 的结果 |
| `GET /healthz` | 健康检查（含 DB、对象存储、模型连通性） |

### 3.4 权限与审计的落地规则（不允许绕过）

1. **外发只有一条路**：`extract_book_knowledge` / `build_daily_task_card` / `judge_retelling` 都不许直接调模型，必须经 `call_model_service`；它先查 `book_consents`，无有效凭据 → `NEED_CONSENT`，**不降级、不静默跳过**，同时写 `outbound_audit`。
2. **每次外发写审计**：记时间、模型名、页/段 id、目的、`consent_id`、`account_id`；**不记正文**。
3. **到期判断在应用侧**：任何读原文/解析全文的路径先查 `originals_expire_at`；到期返回 `BOOK_EXPIRED`，云存储生命周期只作兜底。
4. **删除同步生效**：`frontend_hidden_at` 与删除请求同事务写入；后台清除（`purge_status`）可异步，但前台必须立刻不可见。
5. **书内文本一律当数据**：进入出题/判定前做指令剥离与纯数据封装（PDF 注入防护）。

---

## 4. 指标怎么取数（对着口径写）

**主要指标（7 天内完成 ≥3 卡，上传日起算，判定通过才算完成）：**

```sql
SELECT COUNT(*) FILTER (WHERE is_main_kpi_pass) AS pass_users,
       COUNT(*)                                  AS denominator,      -- 首轮=10
       COUNT(*) FILTER (WHERE is_main_kpi_pass)::numeric / COUNT(*) AS rate
FROM v_kpi_main;
```

**护栏指标（复述有效性，分母含存疑、不含系统错误、同卡取最后一次）：**

```sql
SELECT retelling_pass_rate, denominator FROM v_kpi_guard;   -- 目标 ≥70%
```

**按环节失败率与重试成功率：** 由 `job_queue.kind` + `status` 聚合（parse / extract / card 分开）。
**幂等命中率：** `SUM(hit_count)` vs `COUNT(*)`（`gen_idempotency`）；**重复生成次数应恒为 0**。
**外发确认覆盖率：** `outbound_audit` 中 `consent_id IS NOT NULL` 的比例，**应恒为 100%**。
**删除生效时延：** `delete_audit.purged_at - frontend_hidden_at`（前台立即，后台清除另算）。

---

## 5. 本文引入或暴露的待确认项

| # | 待确认 | 影响 | 建议时点 |
|---|---|---|---|
| 1 | 账号方式（邮箱验证码 / 第三方登录）与 `login_type` 取值 | `accounts` 表结构、登录端点 | 开发前 |
| 2 | 数据库产品（默认 PostgreSQL）与对象存储选型、区域 | DDL 语法、生命周期规则写法 | 开发前 |
| 3 | 模型厂商与模型清单、单本成本上限、时延目标 | `judgements` 的成本字段、超时阈值、`job_queue` 重试上限 | 内部测试前 |
| 4 | 宠物素材规格：性格标签体系、房间主题数量、素材 key 命名 | `pet_asset_map` 与素材包 | 界面设计时 |
| 5 | 到期删除后重读同书：重新上传生成新 `book_id`，还是允许"续读"复用卡片 | `books` 与 `task_cards` 的关系 | 开发前 |
| 6 | 存疑复核的责任人与频率 | `manual_review_queue` 的运营流程 | 试点前 |
| 7 | 用户可见界面（任务卡、宠物房间、删除入口） | 属 UI 原型任务，不在本文范围 | 下一步 |

## 6. 自查（本文的问题，不敢说通过审稿）

- **本文没有经过独立模型审稿**，只有我自查；方案 v3.1 才是经过独立审稿的（86 分）。
- 表结构按 v3.1 的工具与审计要求推导，**没有跑过数据库**，DDL 未做语法验证与性能压测。
- 两个 KPI 视图给了 SQL，但**没在真实数据上验证**；`account_id` 的时区切分依赖 `accounts.timezone` 正确性。
- 状态机覆盖了主要路径，但**并发场景**（同一账号两台设备同时取今日卡、worker 重复租约）只做了设计约束（唯一键 + 租约），未做压测。
- 未包含：UI 原型、提示词细化、部署脚本、迁移文件。

## 7. 下一步可选

1. 按本文生成 **UI 原型**（任务卡 / 复述框 / 宠物房间 / 删除入口）
2. 按本文生成 **代码骨架**（FastAPI 单体 + worker + 9 个工具 + 权限与审计）
3. 先把 §5 的 7 项待确认定掉，再动代码
