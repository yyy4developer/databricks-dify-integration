# Databricks x Dify Integration Patterns

Databricks と Dify の連携パターンを検証するためのリポジトリです。

## 連携パターン一覧

| # | パターン | 概要 | Notebook |
|---|---------|------|----------|
| 1 | LLMモデル連携 | OpenAI互換エンドポイント経由でDatabricks LLMをDifyから利用 | `01_llm_integration` |
| 2 | HTTP API連携 | SQL API, Vector Search, Genie, Serving Endpoints | `02_http_api_integration` |
| 3 | MCP Server連携 | Managed MCP経由でUC Functions/Vector Searchを公開 | `03_mcp_integration` |
| 4 | RAGナレッジ連携 | External Knowledge API経由でVector Searchを接続 | `04_rag_vector_search` |
| 5 | Databricksオーケストレーター | Databricks → Dify方向のバッチ処理 | `05_databricks_orchestrator` |
| 6 | 観測性・MLOps連携 | MLflow Tracing + AI Judge | `06_observability` |

## 環境情報

| 項目 | 値 |
|------|-----|
| Databricks Workspace | `fevm-yao-sl-st.cloud.databricks.com` |
| Catalog | `yao_sl_st_catalog` |
| Schema | `ricoh_handson_code` |
| AI Gateway | `https://7474654222866971.ai-gateway.cloud.databricks.com/mlflow/v1` |
| Dify URL | `http://localhost` |
| Dify Admin | `admin@ricoh-handson.local` / `Ricoh2026Handson!` |

## セットアップ

### 1. Python環境 (uv)

```bash
uv sync
```

### 2. Dify 起動・停止

Difyは `yyy4developer/dify` fork の `databricks-integration` ブランチを git submodule で管理。
カスタム変更の詳細は [dify/CUSTOMIZATIONS.md](https://github.com/yyy4developer/dify/blob/databricks-integration/CUSTOMIZATIONS.md) を参照。

```bash
# submodule初期化（初回のみ）
git submodule update --init

# 起動
cd dify/docker
cp .env.example .env  # 初回のみ
docker compose up -d

# 停止
cd dify/docker
docker compose down

# ログ確認
cd dify/docker
docker compose logs -f api
```

### 3. Databricks Asset Bundle デプロイ

```bash
databricks bundle deploy
```

### 4. 初回Difyセットアップ

1. http://localhost/install にアクセスし管理者アカウント作成
2. OpenAI-API-compatible プラグインをMarketplaceからインストール
3. Model Provider設定:
   - Model Name: `databricks-claude-opus-4-6`
   - Endpoint URL: AI Gateway URL
   - API Key: Databricks PATトークン
   - Completion mode: Chat / Context Size: 200000

## プロジェクト構成

```
.
├── databricks.yml              # Databricks Asset Bundle設定
├── pyproject.toml              # Python依存関係 (uv)
├── notebooks/                  # Databricks Notebooks (DABでデプロイ)
│   ├── config.ipynb            # 共通設定
│   ├── 00_prerequisites.ipynb  # 前提条件の確認
│   ├── 01-06_*.ipynb           # 各連携パターン
│   ├── 07_summary.ipynb        # まとめ
│   └── 99_cleanup.ipynb        # リソースクリーンアップ
├── dify/                       # Dify OSS (git submodule: yyy4developer/dify)
│   ├── CUSTOMIZATIONS.md       # 公式からの変更履歴
│   └── docker/
│       ├── docker-compose.yaml
│       ├── external_knowledge_api/  # Pattern 4 用ミドルウェア
│       └── ssrf_proxy/         # SSRFプロキシ設定
└── docs/
    └── key_points.md           # 技術的知見・ノート
```

## SSRFプロキシ設定

Difyのプラグインやサンドボックスからの外部アクセスはSSRFプロキシ(Squid)経由。
以下のドメインを許可済み（`dify/docker/ssrf_proxy/squid.conf.template`）:
- `.marketplace.dify.ai` / `.pypi.org` / `.pythonhosted.org`
- `.cloud.databricks.com` / `.ai-gateway.cloud.databricks.com`

## トラブルシューティング

- **プラグインインストール失敗**: `docker compose restart ssrf_proxy plugin_daemon`
- **Databricks 403**: VPN接続確認、IP ACLにIP追加
- **"Invalid encrypted data"**: Dify 1.13以降はパスワードをBase64エンコードして送信

詳細は [docs/key_points.md](docs/key_points.md) を参照。
