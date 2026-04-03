#!/bin/bash
# Dify OpenAI-API-compatible プラグインのパッチ
#
# Claude/Gemini系モデルをDatabricks AI Gateway経由で利用する場合、
# プラグインが送信する `user` パラメータを無効化する必要がある。
# （GPT系のみ利用する場合は不要）
#
# Usage:
#   Dify起動後に実行:
#   ./scripts/patch-dify-plugin.sh
#
# 前提:
#   - Dify Docker が起動済み
#   - OpenAI-API-compatible プラグインがインストール済み

set -e

CONTAINER="docker-plugin_daemon-1"

# プラグインファイルを検索
PLUGIN_FILE=$(docker exec "$CONTAINER" find /app/storage/cwd -path "*/openai_api_compatible*/models/llm/llm.py" 2>/dev/null | head -1)

if [ -z "$PLUGIN_FILE" ]; then
    echo "❌ OpenAI-API-compatible プラグインが見つかりません。"
    echo "   Dify UIからプラグインをインストールしてから再実行してください。"
    exit 1
fi

# パッチ済みか確認
if docker exec "$CONTAINER" grep -q "user = None" "$PLUGIN_FILE" 2>/dev/null; then
    echo "✅ パッチ適用済みです（user = None）"
    exit 0
fi

# パッチ適用: super()._invoke() の直前に user = None を挿入
docker exec "$CONTAINER" sed -i \
    's/result = super()._invoke(/# Databricks compatibility: strip user param for Claude\/Gemini\n        user = None\n        result = super()._invoke(/' \
    "$PLUGIN_FILE"

# 確認
if docker exec "$CONTAINER" grep -q "user = None" "$PLUGIN_FILE" 2>/dev/null; then
    echo "✅ パッチ適用完了"
    echo "   plugin_daemon を再起動します..."
    cd "$(dirname "$0")/../dify/docker"
    docker compose restart plugin_daemon
    echo "✅ 再起動完了。Claude/Gemini系モデルが利用可能になりました。"
else
    echo "❌ パッチ適用に失敗しました"
    exit 1
fi
