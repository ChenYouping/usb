#!/bin/bash
# NcmProbe 一键推送 + 触发编译
# 用法：双击运行，或在终端执行 ./push.command "提交说明"

cd "$(dirname "$0")" || exit 1

MSG="${1:-更新 $(date '+%Y-%m-%d %H:%M')}"

echo "==> 1/4 暂存改动"
git add -A

echo "==> 2/4 提交"
if git diff --cached --quiet; then
  echo "    没有改动，跳过提交"
else
  git commit -m "$MSG" || exit 1
fi

echo "==> 3/4 推送代码到 main"
git push origin main || exit 1

echo "==> 4/4 打 tag 触发编译"
TAG="v$(date '+%Y%m%d-%H%M%S')"
git tag "$TAG" || exit 1
git push origin "$TAG" || exit 1

echo ""
echo "✅ 完成！已推送 tag：$TAG"
echo "   GitHub Actions 应该已开始编译，去仓库 Actions 页面看进度。"
echo ""
read -r -p "按回车关闭窗口..."
