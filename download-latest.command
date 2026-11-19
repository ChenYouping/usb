#!/bin/bash
# 自动下载 NcmProbe 最新 Release 的 IPA 到本目录
# 双击运行即可；不需要安装任何额外工具（用系统自带 curl + python3）

cd "$(dirname "$0")" || exit 1

REPO="ChenYouping/usb"
API="https://api.github.com/repos/$REPO/releases/latest"
OUT_DIR="$(cd .. && pwd)"   # 存到上级工作区目录

echo "==> 查询最新 Release …"
RELEASE_JSON=$(curl -s --max-time 20 "$API")
if [ -z "$RELEASE_JSON" ]; then
  echo "❌ 无法连接 GitHub API，检查网络后重试。"
  read -r -p "按回车关闭…"; exit 1
fi

TAG=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null)
ASSET_ID=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); a=d.get('assets') or []; print(a[0]['id'] if a else '')" 2>/dev/null)
ASSET_NAME=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); a=d.get('assets') or []; print(a[0]['name'] if a else 'NcmProbe.ipa')" 2>/dev/null)

if [ -z "$ASSET_ID" ]; then
  echo "❌ 最新 Release 里没有 IPA 资产。"
  read -r -p "按回车关闭…"; exit 1
fi

OUT="$OUT_DIR/NcmProbe-$TAG.ipa"
echo "    最新 tag: $TAG"
echo "==> 下载 IPA …"
# 关键：走 API 的 octet-stream 重定向（-L），让 GitHub 带上一次性签名参数，
# 直接请求 releases/download/... 会因为环境代理 502 而失败。
curl -sL --max-time 180 -H "Accept: application/octet-stream" -o "$OUT" \
  "https://api.github.com/repos/$REPO/releases/assets/$ASSET_ID"

# 校验：IPA 本质是 zip，且应包含 Payload/NcmProbe.app
if ! file "$OUT" | grep -q "Zip archive"; then
  echo "❌ 下载内容不是有效 IPA（可能是网络错误页），已删除。"
  rm -f "$OUT"
  read -r -p "按回车关闭…"; exit 1
fi
if ! unzip -l "$OUT" 2>/dev/null | grep -q "Payload/NcmProbe.app"; then
  echo "❌ IPA 内部结构异常，已删除。"
  rm -f "$OUT"
  read -r -p "按回车关闭…"; exit 1
fi

echo ""
echo "✅ 下载完成：$OUT"
echo "   大小：$(du -h "$OUT" | cut -f1)"
echo ""
echo "下一步：打开 iLoader → Import IPA → 选这个文件 → 安装到手机。"
echo ""
read -r -p "按回车关闭…"
