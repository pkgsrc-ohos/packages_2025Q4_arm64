#!/bin/sh
set -e

# --- 1. 初始化基础变量 ---
WORKDIR=$(pwd)

# 索引文件命名：按照要求，在本地统一使用带 BUCKET 后缀的名称
INDEX_GZ="pkg_summary_${BUCKET}.gz"      # Local Index - Gzip（压缩格式，用于上传/下载）
INDEX_TXT="pkg_summary_${BUCKET}"        # Local Index - Text（文本格式，用于本地操作）
INDEX_TMP="pkg_summary_${BUCKET}.tmp"    # Local Index - Temp（重建索引时的临时文件）

# 包元数据临时文件
PMETA_TMP="package-meta.tmp"  # Package Metadata - Temp（单个包的元数据）

# GitHub API 响应缓存
GHAPI_RESP="release.json"     # GitHub API Response

# 新增：统一存放索引的桶名
SUMMARY_BUCKET="pkg_summary"

# --- 2. 准备构建环境 (pkgsrc 树与工具链) ---
echo ">>> [SETUP] Cloning pkgsrc tree (branch: pkgsrc-2025Q4)..."
cd /opt
git clone --depth 1 -b pkgsrc-2025Q4 https://github.com/pkgsrc-ohos/pkgsrc.git 
echo ">>> [SETUP] Downloading and extracting bootstrap kit..."
curl -fSLO https://github.com/pkgsrc-ohos/packages_2025Q4_arm64/releases/download/bootstrap/bootstrap-ohos-2025Q4-arm64-20260303.tar.gz
tar -zxf bootstrap-ohos-2025Q4-arm64-20260303.tar.gz -C /
cd "$WORKDIR"

# 注入 Bootstrap 工具链路径到当前环境
export PATH=/storage/Users/currentUser/.pkg/bin:/storage/Users/currentUser/.pkg/sbin:$PATH

# 修改个性化配置，启用自动代码签名（这个能力已经添加到 pkgsrc 源码中，打开开关就能启用）
sed -i '/.endif/i OHOS_CODE_SIGN+=\tyes' /storage/Users/currentUser/.pkg/etc/mk.conf

# 传给 bmake 的并行任务数配置
export MAKEFLAGS="MAKE_JOBS=$(nproc)"

# --- 3. 预取 GitHub API 关键端点 ---
echo ">>> [INIT] Fetching Release endpoints for Bucket: $BUCKET and $SUMMARY_BUCKET"

# 获取软件制品桶 (bucket-a/b/c...) 的上传地址与元数据信息
RELEASE_JSON=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
    "https://api.github.com/repos/$REPO_NAME/releases/tags/bucket-$BUCKET")
UPLOAD_URL=$(echo "$RELEASE_JSON" | sed -n 's/.*"upload_url": "\([^"{]*\).*/\1/p')

# 获取统一索引桶 (pkg_summary) 的上传地址
SUMMARY_JSON=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
    "https://api.github.com/repos/$REPO_NAME/releases/tags/$SUMMARY_BUCKET")
SUMMARY_UPLOAD_URL=$(echo "$SUMMARY_JSON" | sed -n 's/.*"upload_url": "\([^"{]*\).*/\1/p')

# API 响应保存为 GHAPI_RESP，供后续查找 Asset ID
echo "$RELEASE_JSON" > "$WORKDIR/$GHAPI_RESP"

# 验证 API 响应，防止后续上传失败
if [ -z "$UPLOAD_URL" ] || [ -z "$SUMMARY_UPLOAD_URL" ]; then
    echo ">>> [ERROR] API failure: Upload URL for bucket-$BUCKET or $SUMMARY_BUCKET is empty."
    exit 1
fi

# --- 4. 同步存量索引（实现增量构建的关键） ---
# 索引现在统一从 pkg_summary 桶中获取
BUCKET_INDEX_URL="https://github.com/$REPO_NAME/releases/download/$SUMMARY_BUCKET/$INDEX_GZ"
echo ">>> [SYNC] Fetching existing index $INDEX_GZ from $SUMMARY_BUCKET..."

if curl -s -L -f -H "Authorization: Bearer $GITHUB_TOKEN" \
    -o "$INDEX_GZ" "$BUCKET_INDEX_URL"; then
    echo ">>> [SYNC] Successfully loaded $INDEX_GZ. Decompressing..."
    gzip -df "$INDEX_GZ"
else
    echo ">>> [SYNC] No existing index found for $BUCKET. Starting fresh."
    : > "$INDEX_TXT"
fi

# 确保解压后的文件存在且可读
[ -f "$INDEX_TXT" ] || : > "$INDEX_TXT"

# --- 5. 解析白名单目标模式 ---
PATTERN="$BUCKET"
[ "$BUCKET" = "0-9" ] && PATTERN="[0-9]"
TARGET_LIST=$(grep -E "^[^/]*/$PATTERN" "$WORKDIR/whitelist.txt" || true)

# --- 6. 核心构建循环 ---
for p_path in $TARGET_LIST; do
    # 路径存在性检查
    if [ ! -d "/opt/pkgsrc/$p_path" ]; then
        echo ">>> [SKIP] Directory /opt/pkgsrc/$p_path not found."
        continue
    fi

    cd "/opt/pkgsrc/$p_path"

    # 获取包属性：P_NAME(带版本号), P_BASE(包名), P_TGZ(制品路径)
    P_NAME=$(bmake show-var VARNAME=PKGNAME)
    P_BASE=$(bmake show-var VARNAME=PKGBASE)
    P_TGZ="/opt/pkgsrc/packages/All/$P_NAME.tgz"

    # 版本检查：如果当前版本已存在于索引，则跳过构建
    if grep -q "^PKGNAME=$P_NAME$" "$WORKDIR/$INDEX_TXT"; then
        echo ">>> [SKIP] $P_NAME is already up-to-date in $INDEX_TXT."
        cd "$WORKDIR"
        continue
    fi

    # 依赖预下载，避免实时构建占用大量时间
    # 安装失败不退出，因为还有实时构建作为兜底
    echo ">>> [PRE-FETCH] Quick-installing dependencies for $P_NAME..."
    RAW_DEPS=$(bmake show-depends-recursive 2>/dev/null)
    if [ -n "$RAW_DEPS" ]; then
        pkgin -y update || true
        for dep_path in $RAW_DEPS; do
            FULL_DEP_PATH="/opt/pkgsrc/$dep_path"
            if [ -d "$FULL_DEP_PATH" ]; then
                DEP_BASE=$(cd "$FULL_DEP_PATH" && bmake show-var VARNAME=PKGBASE)
                pkgin -y install "$DEP_BASE" || true
            fi
        done
    fi

    # 执行构建，失败则回退路径并跳过
    echo ">>> [BUILD] Compiling $P_NAME..."
    if ! bmake package clean; then
        echo ">>> [ERROR] Build failed for $P_NAME."
        cd "$WORKDIR"
        continue
    fi

    # 验证制品生成结果
    if [ ! -f "$P_TGZ" ]; then
        echo ">>> [ERROR] $P_NAME compiled, but $P_TGZ is missing."
        cd "$WORKDIR"
        continue
    fi

    # --- 7. 上传与索引更新 ---

    # 上传二进制包
    echo ">>> [UPLOAD] Binary: $P_NAME.tgz"
    curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
         -H "Content-Type: application/octet-stream" \
         --data-binary @"$P_TGZ" \
         "$UPLOAD_URL?name=$P_NAME.tgz"

    # 生成包元数据 -> 过滤掉所有空行 -> 追加 PKG_URL -> 补一个标准的段落分隔空行
    pkg_info -X "$P_TGZ" | grep . > "$WORKDIR/$PMETA_TMP"
    echo "PKG_URL=https://github.com/$REPO_NAME/releases/download/bucket-$BUCKET/$P_NAME.tgz" >> "$WORKDIR/$PMETA_TMP"
    echo "" >> "$WORKDIR/$PMETA_TMP"

    # 更新本地索引：删除旧记录（实现修订版本替换的关键），追加新记录
    awk -v base="$P_BASE" '
    BEGIN { RS=""; ORS="\n\n" }
    !($0 ~ ("^PKGBASE=" base "$") || $0 ~ ("\nPKGBASE=" base "\n"))
    ' "$WORKDIR/$INDEX_TXT" > "$WORKDIR/$INDEX_TMP" 2>/dev/null || true

    cat "$WORKDIR/$PMETA_TMP" >> "$WORKDIR/$INDEX_TMP"
    mv "$WORKDIR/$INDEX_TMP" "$WORKDIR/$INDEX_TXT"

    gzip -c "$WORKDIR/$INDEX_TXT" > "$WORKDIR/$INDEX_GZ"

    # 重新获取 pkg_summary 桶的信息，确保 Asset ID 准确
    SUMMARY_REFRESH=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
        "https://api.github.com/repos/$REPO_NAME/releases/tags/$SUMMARY_BUCKET")

    ASSETS_ID=$(echo "$SUMMARY_REFRESH" | grep -B 2 "\"name\": \"$INDEX_GZ\"" | grep "\"id\":" | sed 's/[^0-9]//g')

    # 同步到 Release：从统一桶中删除旧索引，上传新索引
    if [ -n "$ASSETS_ID" ]; then
        curl -s -X DELETE -H "Authorization: Bearer $GITHUB_TOKEN" \
             "https://api.github.com/repos/$REPO_NAME/releases/assets/$ASSETS_ID"
    fi

    curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
         -H "Content-Type: application/gzip" \
         --data-binary @"$WORKDIR/$INDEX_GZ" \
         "$SUMMARY_UPLOAD_URL?name=$INDEX_GZ"

    echo ">>> [SUCCESS] $P_NAME synchronized to $SUMMARY_BUCKET."

    # 返回工作目录，开启下一轮构建
    cd "$WORKDIR"
done

echo ">>> [FINISHED] Bulk build for bucket $BUCKET completed successfully."
