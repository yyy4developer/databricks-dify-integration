# Databricks x Dify 連携検証 — 技術的知見

本ドキュメントは、Databricks x Dify 連携検証で得られた技術的知見を整理・統合したリファレンス資料である。

---

## 1. 各パターンの検証結果サマリ

| # | パターン | 方向 | 検証状況 | 長所 | 短所・制約 |
|---|---------|------|---------|------|-----------|
| ① | LLMモデル連携 | Dify→DB | ✅ 検証済み | LLMの一元管理・コスト制御。GPT系はパッチ不要 | Claude/Gemini系はプラグインパッチ必要 |
| ② | HTTP API連携 | Dify→DB | ✅ 検証済み | UC Functions・Vector Search・Genie・KA/MAS/Agent全て呼出可能 | Genieは非同期ポーリング要。ResponsesAgent形式は変換要 |
| ③ | MCP連携 | Dify→DB | ✅ 検証済み | 標準プロトコルでツール公開。設定が容易 | MCP SSEプラグイン依存。Vector Searchの引数名がREST APIと異なる |
| ④ | RAG（External Knowledge） | Dify→DB | ⚠️ 紹介のみ | Dify標準ナレッジ機能の活用 | Vector Search APIとDify External Knowledge APIのフォーマット不一致。変換用中間APIサーバーが必要 |
| ⑤ | Databricksオーケストレーター | DB→Dify | ⚠️ 紹介のみ | 大規模バッチAI処理に有効 | ローカルDockerのDifyにはDatabricksからアクセス不可（Cloud/パブリックデプロイが必要） |
| ⑥ | 観測性/MLOps | Dify→DB | ✅ 検証済み | MLflow Experiment にトレース送信。AI Judgeで品質自動評価 | Experiment IDがワークスペース共有。一部バグあり |

### 段階的導入ロードマップ

| Phase | 期間 | パターン | 目的 |
|-------|------|---------|------|
| Phase 1 | 1-2ヶ月 | ① LLM + ③ MCP + ⑥ トレーシング | Quick Win: 最小限の変更でガバナンス効果を実感 |
| Phase 2 | 2-4ヶ月 | ② HTTP API拡張 + 認証強化 + AI Judge運用 | Deep Integration: ツール・ナレッジの一元化 |
| Phase 3 | 4-6ヶ月 | ⑤ バッチ処理 + ④ External Knowledge + Databricks Apps | Full Governance: バッチ処理・品質管理の統合 |

---

## 2. LLMモデル互換性

### モデルファミリー別の対応状況

DifyのOpenAI-API-compatibleプラグインは全リクエストに `user` パラメータを付与する。Databricks FMAPI側の対応状況は以下の通り。

| モデルファミリー | `user`パラメータ | Difyとの相性 |
|-----------------|-----------------|-------------|
| GPT系 | 受け入れる | そのまま動作 |
| Claude系 | 拒否する | プラグインパッチ必要 |
| Gemini系 | 拒否する | プラグインパッチ必要 |
| AI Gateway（カスタムルート） | 拒否する | プラグインパッチ必要 |

### Claude/Gemini系パッチ方法

プラグインの `models/llm/llm.py` の `_invoke` メソッド内、`super()._invoke()` 直前に以下を追加:

```python
# Strip user param for Databricks compatibility
user = None
```

適用コマンド:
```bash
PLUGIN_DIR="/app/storage/cwd/langgenius/openai_api_compatible-0.0.40@.../models/llm/llm.py"
docker compose exec plugin_daemon sed -i \
  's/result = super()._invoke(/# Strip user param for Databricks compatibility\n        user = None\n        result = super()._invoke(/' \
  "$PLUGIN_DIR"
docker compose restart plugin_daemon
```

### Anthropicプラグインが使えない理由

Dify公式Anthropicプラグインは認証ヘッダーが `x-api-key` 固定。Databricksは `Authorization: Bearer` を要求するため接続不可。

### 推奨

- **メイン**: GPT系モデル（パッチ不要で最も簡単）
- **上級者向け**: Claude系（パッチ適用が必要）

---

## 3. 認証・権限管理

### パターン別の認証構造

| パターン | 必要なもの | 権限チェック |
|---------|----------|------------|
| SQL API（UC関数） | PAT + warehouse_id | Warehouse CAN USE + UC EXECUTE FUNCTION |
| Vector Search | PAT | UC SELECT on index |
| Genie | PAT + space_id | Space CAN VIEW |
| KA/MAS/Agent | PAT | Endpoint CAN QUERY（内部はSPの権限で実行） |
| MCP | PAT（headers内） | UC権限がMCP経由でも維持 |

### Dify運用時の制約: 全ユーザーが同一権限

```
User A ─┐                   固定PAT（SP）
User B ─┼─▶ Dify App ──────────────▶ Databricks
User C ─┘   全員が同じ権限         UC権限で制御
```

Difyアプリには固定のPATが埋め込まれるため、ユーザー単位のアクセス制御は不可。これはDifyの制約であり、Databricks側の問題ではない。

### ユーザー別アクセス制御が必要な場合

| 方式 | セキュリティ | 推奨場面 |
|------|-----------|---------|
| Dify App x SP分離 | ○ ロール単位 | 部門別にデータを分けたい |
| Dify API + inputs経由でPAT渡し | △ PATがDifyを通過 | 技術的に可能だが複雑 |
| **Databricks Apps（OAuth U2M）** | **◎ ユーザー単位** | **厳格な制御が必要な場合** |

### MCP設定におけるPATの扱い

- Dify DB上はPKCS1_OAEP暗号化で保存される
- ただしDify管理者は設定画面から閲覧可能
- OAuth M2Mの動的トークン取得には未対応（プラグインの制約）

### PAT vs OAuth M2M

| 観点 | PAT | OAuth M2M |
|------|-----|-----------|
| トークン寿命 | 長期（手動管理） | 短期（自動ローテーション） |
| 漏洩リスク | 高（漏れたら即悪用） | 低（1時間で失効） |
| Difyでの利用 | ◎ Bearer埋めるだけ | △ トークン取得の仕組みが必要 |

### ベストプラクティス

1. **専用サービスプリンシパル（SP）を作成**（個人PATは使わない）
2. SPに**必要最小限のUC権限のみGRANT**
3. Dify専用の**小型warehouseを割り当て**（コスト分離）
4. Dify管理者を限定（PAT閲覧者の制限）

---

## 4. MCP連携の知見

### プロトコル

- Databricks Managed MCP（Streamable HTTP）でUC FunctionsとVector Searchをツールとして公開
- MCPの実体はJSON-RPC over HTTP（`initialize` → `tools/list` → `tools/call`）
- DifyからはMCP SSEプラグイン（`junjiem/mcp_sse`）で接続

### ツールディスカバリ

MCPサーバーの `tools/list` でUC FunctionsとVector Searchが自動的にツールとして列挙される。

### Vector Search引数の差異

MCPの引数は `query`（REST APIでは `query_text`）。パラメータ名が異なる点に注意。

### Genie MCP

`/api/2.0/mcp/genie/{space_id}` エンドポイントが利用可能。

### Dify MCP SSEプラグイン要件

- `junjiem/mcp_sse` プラグインをインストール
- `headers` にPATを平文で設定する必要あり
- OAuth M2Mの動的トークン取得には未対応

### コードAgentとの関係

エンドポイント丸ごとラップ（`ai_query()` → UC Function → MCP → Dify）は技術的に可能だが、Difyのオーケストレーション力を活かすなら、**部品（UC Functions + Vector Search）を直接MCP公開**してDify側で組み立てる方がベスト。

`ai_query()` を使えばSQL1行でServing EndpointをUC Functionに変換可能:

```sql
CREATE OR REPLACE FUNCTION catalog.schema.ask_agent(
  question STRING COMMENT 'ユーザーの質問'
)
RETURNS STRING
COMMENT 'TechNovaエージェントに質問する'
RETURN ai_query('serving_endpoint_name', question);
```

### ai_query() vs Python UC Function

| 観点 | Python UC Function | ai_query() |
|------|-------------------|------------|
| コード量 | ~10行（requests使用） | 1行 |
| 認証 | トークン管理が必要 | 自動 |
| エラーハンドリング | 自前実装 | 組込み |
| SQL内での利用 | 不可 | 可（SELECTで直接使える） |

### ai_query()の制約

| 制約 | 内容 |
|------|------|
| タイムアウト | マルチステップ推論でSQL実行制限に引っかかる可能性 |
| ストリーミング不可 | 応答は全完了後に返却 |
| 会話履歴なし | ステートレス（マルチターン不可） |
| ResponsesAgent形式 | 新しい形式との互換性は要テスト |

---

## 5. Observability（MLflow Tracing）の制約

### Databricksネイティブプロバイダー

Dify v1.10.1で追加されたDatabricks専用トレーシングプロバイダー。Agent/Chatbot/Workflowの全アプリタイプでMLflow Experimentにトレース送信可能。

| 連携案 | 仕組み | 推奨度 |
|-------|--------|--------|
| **Databricksネイティブ** | Dify組み込みプロバイダーで直接送信 | **◎ 推奨** |
| MLflowプロバイダー | OSS MLflowサーバー経由 | ○ |
| Langfuse経由 | Dify→Langfuse→ETL→Databricks | △ |

### Experiment IDスコープ

DatabricksプロバイダーのExperiment ID設定は**アプリごとに個別設定可能**。各アプリのMonitoring → Settingsで異なるExperiment IDを指定できる。

```
Difyワークスペース
  ├── MCP Agent App   ──▶ Experiment A (ID: 123)
  ├── Workflow App     ──▶ Experiment B (ID: 456)
  └── Chatbot App     ──▶ Experiment C (ID: 789)
```

> 注意: 各アプリのMonitoringで個別に設定が必要（一括設定はない）。API (`/apps/<app_id>/trace-config`) でも設定可能。

### スパンタイプとapp_nameの制約

| 構成 | RETRIEVERスパン | app_name | RetrievalGroundedness |
|------|---------------|----------|---------------------|
| Dify標準ナレッジのChatbot | ✅ | ❌ | ✅（理論上） |
| Workflowのナレッジ検索ノード | ✅ | ✅ | ✅（理論上） |
| MCP経由のVector Search | ❌（TOOLになる） | ❌ | ❌ |

- `app_name` はWorkflowの子スパンのattributesにのみ含まれる
- Agent/Chatbotのトレースには `app_name` が含まれない
- MCP経由のVector SearchはDifyの `RETRIEVER` スパンを通らないため `TOOL` タイプになる

### アプリの識別方法

`tags['mlflow.traceName']`（スパン名）で種類を識別:

| スパン名 | 意味 |
|---------|------|
| `message` | Agent/ChatbotのLLM呼び出し |
| `mcp_sse_call_tool` | MCPツール呼び出し |
| `workflow` | Workflowアプリのルートスパン |
| `generate_conversation_name` | 会話タイトル生成（評価対象外） |

### AI Judge自動評価（3段階）

| 評価 | 対象 | Scorer | 内容 |
|------|------|--------|------|
| A | LLM最終回答 | Safety, Guidelines | 安全性、日本語品質、事実性 |
| B | 検索結果+回答 | Guidelines（カスタム） | 回答が検索コンテキストに基づいているか |
| C | 全スパン | パフォーマンス分析 | レイテンシ、ボトルネック検出 |

### 既知のバグ（Dify v1.13.0）

External Knowledge（外部ナレッジ）を使うChatbotでトレースが送信されない:

```
ops_trace_manager.py:797 dataset_retrieval_trace
  start_time=timer.get("start")
  AttributeError: 'NoneType' object has no attribute 'get'
```

`dataset_retrieval_trace` でタイマー情報が `None` になり、全トレース処理がクラッシュする。MCP Agent構成では `dataset_retrieval` を通らないため影響なし。修正されるまで **External Knowledge + トレーシング併用は不可**。

### MLflow Trace Table（UC Delta Table）

MLflow 3.9+ で `set_experiment_trace_location()` を使い、トレースをUC Delta tableに保存可能。

- 自動生成テーブル: `mlflow_experiment_trace_otel_spans`, `_otel_logs`, `_otel_metrics`, `_metadata`, `_unified`
- SQLで直接分析可能（スパン分布、レイテンシP95、時系列分析等）
- **制約**: 既存トレースがあるExperimentにはリンク不可（新しいExperimentが必要）
- **要件**: "OpenTelemetry on Databricks" preview有効

方式Aと組み合わせて使用推奨: DifyネイティブプロバイダーでExperimentに送信 → UC tableにリンクして長期保存・SQL分析。

### Zerobus OpenTelemetry（Dify OTEL連携）

Difyは PR #17627 (2025-04-11 merged) でOpenTelemetry対応。`ENABLE_OTEL=true` で有効化。

検証結果:
- **OTLPエンドポイント**: `https://<workspace>/api/2.0/otel/v1/traces` はBeta利用可能
- **カスタムヘッダー必要**: `X-Databricks-UC-Table-Name` をDifyのext_otel.pyに追加する修正が必要
- **結果**: 1545 spans がUC Delta tableに到着
- **トレース内容**: インフラレベル（DB SELECT/INSERT, Redis, HTTP, Celery）— LLM/ツール呼び出しは含まない
- **service.name**: `langgenius/dify` で識別可能

**方式Aとの補完関係**:
| 方式 | トレース内容 | アプリ区別 |
|------|------------|----------|
| A: ネイティブ | LLM応答、ツール呼び出し | × |
| C: OTEL | インフラ（DB, Redis, HTTP） | △ service.name |

### 3方式の比較

| 観点 | A: ネイティブ | B: Trace Table | C: Zerobus OTEL |
|------|-------------|---------------|-----------------|
| 設定容易さ | ◎ UI設定のみ | ○ MLflow API | △ env + コード修正 |
| トレース内容 | LLM/ツール | Aと同じ（UC保存） | インフラ（DB/Redis/HTTP） |
| アプリ区別 | ○ Experiment分離 | ○ (Aと同じ) | △ service.name |
| SQL分析 | × (MLflow API) | ◎ | ◎ |
| 長期保存 | △ Experiment依存 | ◎ UC table | ◎ UC table |
| 対応状況 | ✅ GA | ✅ Preview | ⚠️ Beta + コード修正 |
| **推奨** | **即時利用** | **A+B併用推奨** | **将来本番向け** |

---

## 6. HTTP APIの互換性

### 検証済みAPI一覧

| API | エンドポイント | 形式 | Dify連携 |
|-----|-------------|------|----------|
| **UC Functions** | `POST /api/2.0/sql/statements/` | 同期REST | ◎ 最もシンプル |
| **Vector Search** | `POST /api/2.0/vector-search/indexes/{name}/query` | 同期REST | ◎ シンプル |
| **Genie** | `POST /api/2.0/genie/spaces/{id}/start-conversation` | 非同期REST（ポーリング必要） | △ ループ実装が必要 |
| **Knowledge Assistant (KA)** | `POST /serving-endpoints/ka-{id}-endpoint/invocations` | ResponsesAgent | ○ 同期だが形式変換要 |
| **Supervisor Agent (MAS)** | `POST /serving-endpoints/mas-{id}-endpoint/invocations` | ResponsesAgent | ○ 同期だが形式変換要 |
| **Code Agent** | `POST /serving-endpoints/{name}/invocations` | ResponsesAgent | ○ 同期だが形式変換要 |

全APIで `Authorization: Bearer <PAT>` による認証。

### ResponsesAgent形式の注意点

KA/MAS/Code Agentは全て同じResponsesAgent形式（`input`/`output`）。DifyのOpenAI-API-compatibleプラグインが期待する `messages`/`choices` 形式とは異なるため、**LLMモデルとしては接続不可**。HTTPリクエストノードで呼び出し、レスポンスをJSONパースする。

```json
// リクエスト
{"input": [{"role": "user", "content": "質問"}]}

// レスポンス
{"output": [{"role": "assistant", "content": [{"type": "output_text", "text": "回答"}]}]}
```

`output` 配列に `function_call` / `function_call_output` / `message` が混在する。最終回答は `type=message` のみ抽出する。

### コードAgentのDify連携方法

コードAgent（LangGraph + Model Serving）はResponsesAgent形式のため、DifyのLLMモデルとしては接続不可。連携方法の選択肢:

| 方式 | 概要 | 推奨度 |
|------|------|--------|
| HTTP APIツール（Pattern ②） | DifyのWorkflow/ChatflowのHTTPリクエストノードで直接呼び出し | △ |
| ai_query() + UC Function + MCP（Pattern ③） | ai_queryでラップしてMCP公開 | ○ |
| 部品を直接MCP公開（UC Functions + Vector Search） | エンドポイントではなく部品を公開 | ◎ |

> コードAgentとDifyは対立ではなく、**部品をDatabricksで共有し、UIを使い分ける**のが正しいアーキテクチャ。

### Genie APIの特殊性

Genieは非同期APIで3ステップ必要:

1. `POST start-conversation` → `conversation_id`, `message_id` を取得
2. `GET messages/{msg_id}` をポーリング（3秒間隔、statusが `COMPLETED` になるまで）
3. `attachments[].text` から回答、`attachments[].query.query` から生成SQLを取得

**制約**: 5リクエスト/分/ワークスペース（POSTのみカウント、GETポーリングはカウント外）

---

## 7. 推奨アーキテクチャ

### 現状の課題: Difyアプリ乱立問題

Difyの各アプリ（DSLファイル）にモデル・ツール・ナレッジが個別に埋め込まれている。

```
DSL(モデル+ツール+ナレッジ)   ← 全部バラバラ
DSL(モデル+ツール+ナレッジ)
DSL(モデル+ツール+ナレッジ)
```

- アプリごとにモデル設定が重複
- ツール・ナレッジが散在し再利用できない
- 誰が何を作ったか把握できない（ガバナンス欠如）

### 設計思想: Difyを薄いUI層にする

DSLの中身（部品）をDatabricksに引き上げ、Difyはプロンプトとフロー定義のみを担当する。

```
Databricks（ガバナンス基盤）
┌──────────────────────────────────┐
│ モデル    → AI Gateway（コスト制御）     │
│ ツール    → UC Functions（権限管理）     │
│ ナレッジ  → Vector Search（一元管理）    │
│ 観測性    → MLflow Tracing（品質評価）   │
└──────────────┬───────────────────┘
               │ API / MCP
        ┌──────┼──────┐
       Dify   Dify   Databricks Apps
      (軽量)  (軽量)  (OAuth U2M)
       ↑ UIとプロンプトだけ
```

### 管理対象の移行

| 管理対象 | 現状（Dify内） | 目標（Databricks） |
|---------|-------------|------------------|
| LLMモデル | 各アプリに個別設定 | AI Gatewayで一元管理・コスト制御 |
| ツール | 各アプリに個別実装 | UC Functionsで共有・権限管理 |
| ナレッジ | 各アプリに個別ナレッジ | Vector Searchで一元管理 |
| 品質管理 | なし | MLflow Tracing + AI Judge |
| DSLファイル | モデル+ツール+ナレッジ全部入り | UIとプロンプトだけの薄い層 |

> **核心メッセージ**: DSLファイルを管理するのではなく、DSLの中身（部品）をDatabricksに引き上げるのが本質。アプリが乱立しても、部品はDatabricks側で統制できるので影響が最小化される。

### コードAgentとの関係

コードAgent（LangGraph + Python）とDify連携（ノーコード/ローコード）は対立ではなく、**部品をDatabricksで共有し、UIを使い分ける**のが正しいアーキテクチャ。

| | コードAgent | Dify連携 |
|--|------------|---------|
| 開発手法 | LangGraph + Python | ノーコード/ローコード |
| デプロイ | Model Serving Endpoint | Dify Docker |
| 共通部品 | UC Functions, Vector Search | **同じ部品を共有** |
| 公開方法 | REST API (ResponsesAgent) | MCP / HTTP API |

### Phase別ロードマップ

**Phase 1: Quick Win（1-2ヶ月）**

| 施策 | 内容 |
|------|------|
| LLMモデル連携 | AI Gateway経由でGPT系モデルをDifyから利用 |
| MCP連携 | UC Functions + Vector SearchをMCPで公開 |
| トレーシング | DatabricksプロバイダーでMLflowにトレース送信 |

具体的なPoC内容:
1. 実業務データでUC Functions（顧客検索、注文履歴等）を作成
2. ドキュメントでVector Search Indexを構築
3. MCP経由でDify Agentに接続し社内サポートBotとして運用開始
4. MLflowトレーシングで品質モニタリング

**Phase 2: Deep Integration（2-4ヶ月）**

| 施策 | 内容 |
|------|------|
| HTTP API拡張 | Genie連携（自然言語SQL）、KA/MAS呼び出し |
| 認証強化 | 専用SP作成 + UC権限の最小化 |
| AI Judge運用 | 品質評価の自動化（Workflow定期実行） |

**Phase 3: Full Governance（4-6ヶ月）**

| 施策 | 内容 |
|------|------|
| バッチ処理 | Databricks WorkflowからDify APIでバッチAI処理 |
| External Knowledge | 中間API構築でDify標準ナレッジ機能を活用 |
| Databricks Apps | ユーザー単位の権限制御が必要な場面でOAuth U2Mアプリ |
