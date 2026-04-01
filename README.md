# Databricks x Dify Integration Patterns

Databricks と Dify の連携パターンを検証するためのリポジトリです。
Databricksにある程度詳しい方が、ガイドに従って自走でhands-on検証できることを目指しています。

## 連携パターン一覧

| # | パターン | 方向 | 概要 | Notebook |
|---|---------|------|------|----------|
| 1 | LLMモデル連携 | Dify→DB | OpenAI互換エンドポイント経由でDatabricks LLMをDifyから利用 | `01_llm_integration` |
| 2 | HTTP API連携 | Dify→DB | SQL API, Vector Search, Genie, Serving Endpoints | `02_http_api_integration` |
| 3 | MCP Server連携 | Dify→DB | Managed MCP経由でUC Functions/Vector Search/Genieを公開 | `03_mcp_integration` |
| 4 | RAGナレッジ連携 | Dify→DB | External Knowledge API経由でVector Searchを接続 | `04_rag_vector_search` |
| 5 | Databricksオーケストレーター | DB→Dify | Databricks → Dify方向のバッチ処理 | `05_databricks_orchestrator` |
| 6 | 観測性・MLOps連携 | 双方向 | MLflow Tracing + AI Judge | `06_observability` |

## 前提条件

- Databricks Workspace（Unity Catalog有効）
- Docker / Docker Compose
- Python 3.11+ / uv
- VPN接続（IP ACL付きワークスペースの場合）

## セットアップ手順

### 1. リポジトリのクローン

```bash
git clone --recurse-submodules https://github.com/yyy4developer/databricks-dify-integration.git
cd databricks-dify-integration
```

### 2. 設定ファイルの編集

```bash
# シークレット設定
cp .env.example .env
# .env を編集: DATABRICKS_HOST, DATABRICKS_TOKEN を設定

# パラメータ設定
# config.yaml を編集: catalog, schema, endpoint名等を設定
```

### 3. Difyの起動と初期設定

```bash
# Dify起動
cd dify/docker
cp .env.example .env
docker compose up -d

# ログ確認
docker compose logs -f api
```

ブラウザで http://localhost にアクセスし、以下を実施:

1. **管理者アカウント作成**: http://localhost/install でメール・パスワードを設定
2. **プラグインインストール**: Settings → Plugin → Marketplace から以下をインストール
   - `OpenAI-API-compatible` （Pattern 1, 2, 4, 6 で使用）
   - `MCP SSE` （Pattern 3 で使用、v0.2.3以上）
3. **Model Provider設定**: Settings → Model Provider → OpenAI-API-compatible
   - Model Name: `config.yaml` の `llm_endpoint_name` と同じ値
   - API endpoint URL: AI Gateway URL または `https://<workspace>/serving-endpoints/<model>/invocations`
   - API Key: Databricks PAT
   - Completion mode: Chat

> **SSRFプロキシ**: Difyからの外部アクセスはSSRFプロキシ(Squid)経由です。
> `.cloud.databricks.com` と `.ai-gateway.cloud.databricks.com` は許可済み。
> カスタム変更の詳細は [dify/CUSTOMIZATIONS.md](https://github.com/yyy4developer/dify/blob/databricks-integration/CUSTOMIZATIONS.md) を参照。

### 4. Databricksリソースの構築

Databricks Workspaceで `notebooks/00_data_setup.ipynb` を実行:
- Catalog / Schema / Volume 作成
- テーブル作成（products, customers, orders, support_tickets, policies）
- PDFアップロード → knowledge_base テーブル生成

### 5. DSLインポート（オプション）

`dsl/` にDifyアプリ定義ファイルがあります。Dify UI → **Studio** → **Import DSL File** でインポート可能。

| ファイル | パターン |
|---------|---------|
| `01_LLM_endpoint.yml` | Pattern 1: LLMモデル連携 |
| `02_UC_SQL_API.yml` | Pattern 2: UC関数実行 |
| `02_Vector_Search.yml` | Pattern 2: Vector Search |
| `02_Genie_API.yml` | Pattern 2: Genie API |
| `03_MCP_Agent.yml` | Pattern 3: MCP Agent |
| `04_RAG_Chatbot.yml` | Pattern 4: RAG Chatbot |

`dsl/optional/` にはKA/MAS/Agent用のDSLもあります（構築済み環境向け）。

> **注意**: インポート後、Model ProviderのAPI Key（Databricks PAT）は各自で設定が必要です。

### 6. Hands-on開始

`notebooks/01_llm_integration.ipynb` から順に実施してください。
各notebookには必要なDatabricksリソースの構築手順が含まれています。

## プロジェクト構成

```
.
├── config.yaml                 # パラメータ設定
├── .env.example                # シークレットテンプレート
├── databricks.yml              # Databricks Asset Bundle設定
├── pyproject.toml              # Python依存関係 (uv)
├── pdfs/                       # PDFドキュメント（Volume uploadに使用）
├── dsl/                        # Difyアプリ定義（DSLエクスポート）
│   └── optional/               # KA/MAS/Agent用（構築済み環境向け）
├── notebooks/
│   ├── _config.ipynb           # 共通設定（config.yaml読み込み）
│   ├── 00_data_setup.ipynb     # Databricksリソース構築
│   ├── 01-06_*.ipynb           # 各連携パターン
│   └── 99_cleanup.ipynb        # リソースクリーンアップ
├── dify/                       # Dify OSS (git submodule: yyy4developer/dify)
│   └── CUSTOMIZATIONS.md       # 公式からの変更履歴
└── docs/
    ├── key_points.md           # 技術ノート
    └── findings.md             # 検証で判明した技術的知見
```

## トラブルシューティング

- **プラグインインストール失敗**: `docker compose restart ssrf_proxy plugin_daemon`
- **Databricks 403**: VPN接続確認、IP ACLにIP追加
- **"Invalid encrypted data"**: Dify 1.13以降はパスワードをBase64エンコードして送信
- **Redis RDB エラー**: `docker exec docker-redis-1 redis-cli CONFIG SET stop-writes-on-bgsave-error no`

## クリーンアップ

検証終了後、`notebooks/99_cleanup.ipynb` を実行してDatabricksリソースを削除してください。

```bash
# Dify停止
cd dify/docker
docker compose down
```

## 参考資料

- [docs/findings.md](docs/findings.md) — 検証で判明した技術的知見
- [docs/key_points.md](docs/key_points.md) — 詳細な技術ノート
- [Dify CUSTOMIZATIONS.md](https://github.com/yyy4developer/dify/blob/databricks-integration/CUSTOMIZATIONS.md) — Dify本体のカスタム変更
