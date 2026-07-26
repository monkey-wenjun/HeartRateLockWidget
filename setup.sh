#!/bin/bash
# HeartRateLockWidget 一键配置脚本
# 运行前请确保已安装 XcodeGen：brew install xcodegen

set -e

echo "=== HeartRateLockWidget 项目配置 ==="
read -p "请输入 Bundle ID 前缀 (例如 com.yourname): " BUNDLE_PREFIX
read -p "请输入 Apple Development Team ID (可在 Xcode Signing & Capabilities 中查看，可直接回车): " TEAM_ID
read -p "请输入 App Group ID (例如 group.com.yourname.heartratelock): " APP_GROUP

if [[ -z "$BUNDLE_PREFIX" || -z "$APP_GROUP" ]]; then
    echo "错误：Bundle ID 前缀和 App Group ID 不能为空"
    exit 1
fi

if ! command -v xcodegen &> /dev/null; then
    echo "错误：未找到 xcodegen。请先安装: brew install xcodegen"
    exit 1
fi

# 从模板生成用户配置
cp project.yml project.user.yml
sed -i '' "s|__BUNDLE_ID_PREFIX__|$BUNDLE_PREFIX|g" project.user.yml
sed -i '' "s|__TEAM_ID__|$TEAM_ID|g" project.user.yml
sed -i '' "s|__APP_GROUP__|$APP_GROUP|g" project.user.yml

# 同步源码中的 App Group（整行替换，支持重复运行）
sed -i '' 's|public static let appGroupIdentifier = ".*"|public static let appGroupIdentifier = "'"$APP_GROUP"'"|' HeartRateLockShared/SharedConfig.swift
# 同步 Widget Bundle ID（共享文件放在 Widget 容器里，路径依赖它）
sed -i '' 's|public static let widgetBundleIdentifier = ".*"|public static let widgetBundleIdentifier = "'"$BUNDLE_PREFIX"'.HeartRateLock.widget"|' HeartRateLockShared/SharedConfig.swift

# 生成 Xcode 项目
xcodegen generate --project . --spec project.user.yml

echo ""
echo "✅ 已生成 HeartRateLockWidget.xcodeproj"
echo "下一步："
echo "1. 用 Xcode 打开 HeartRateLockWidget.xcodeproj"
echo "2. 在 Targets -> HeartRateLock / HeartRateWidget 的 Signing & Capabilities 中选择你的 Team"
echo "3. 确保 Apple Developer 账号中已注册 App Group: $APP_GROUP"
echo "4. 先运行 HeartRateLock target，再运行 Widget Extension"
