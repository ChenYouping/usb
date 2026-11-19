#!/bin/bash
# 自动下载 NcmProbe 最新 Release 的 IPA 到工作区目录
# 双击运行即可；不需要安装任何额外工具（系统自带 curl）
# 不依赖 GitHub API，避免匿名限流（60次/小时）导致失败。

cd "$(dirname "$0")" || exit 1

REPO="ChenYouping/usb"
OUT_DIR="$(cd .. && pwd)"   # 存到上级工作区目录

echo "==> 解析最新 Release 下载链接 …"
DL="https://github.com/$REPO/releases/latest/download/NcmProbe.ipa"
# 跟随 302 拿到带一次性签名的 release-assets 直链（存到临时 header 文件）
HDR=$(mktemp)
curl -sL --max-time 25 -D "$HDR" -o /dev/null "$DL"
DIRECT=$(grep -i "^location:" "$HDR" | tail -1 | sed 's/^[Ll]ocation: //' | tr -d '\r')
TAG=$(curl -sL --max-time 15 -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed 's#.*/tag/##')
rm -f "$HDR"

if [ -z "$DIRECT" ]; then
  echo "❌ 无法解析下载链接，检查网络后重试。"
  read -r -p "按回车关闭…"; exit 1
fi

OUT="$OUT_DIR/NcmProbe-$TAG.ipa"
echo "    最新 tag: $TAG"
echo "==> 下载 IPA …"
curl -sL --max-time 120 -o "$OUT" "$DIRECT"

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
