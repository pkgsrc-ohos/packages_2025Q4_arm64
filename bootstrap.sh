#!/bin/sh
set -e

WORKDIR=$(pwd)

# 下载 pkgsrc 源码树
cd /opt
git clone --depth 1 -b pkgsrc-2025Q4 https://github.com/pkgsrc-ohos/pkgsrc.git

# bootstrap
cd /opt/pkgsrc/bootstrap
./bootstrap \
    --prefix /storage/Users/currentUser/.pkg \
    --varbase /storage/Users/currentUser/.pkg/var \
    --pkgdbdir /storage/Users/currentUser/.pkg/pkgdb \
    --prefer-pkgsrc yes \
    --compiler clang

# 修改个性化配置，让仓库里面所有把 openssl 视为可选依赖的软件包全部启用 openssl
sed -i '/.endif/i PKG_DEFAULT_OPTIONS+=\topenssl' /storage/Users/currentUser/.pkg/etc/mk.conf

# 把“干净”的 .pkg 目录复制一份备份起来
cp -r /storage/Users/currentUser/.pkg /storage/Users/currentUser/.pkg-backup

export MAKEFLAGS="MAKE_JOBS=$(nproc)"
export PATH=/storage/Users/currentUser/.pkg/bin:/storage/Users/currentUser/.pkg/sbin:$PATH

# 需要预置在 bootstrap kit 里面的软件包
PACKAGES="pkgtools/pkgin
security/mozilla-rootcerts"

# 循环构建它们，产生的包会存放在 /opt/pkgsrc/packages/All
# 此时 .pkg 目录里面会带有大量构建期依赖
for pkg in $PACKAGES; do
    cd "/opt/pkgsrc/$pkg"
    bmake package clean
done

# 把这个“脏了”的 .pkg 目录删掉，再把“干净”的 .pkg 目录移回来
rm -r /storage/Users/currentUser/.pkg
mv /storage/Users/currentUser/.pkg-backup /storage/Users/currentUser/.pkg

# 通过二进制安装的方式，把这些预置包装到“干净”的目录里面，
# 此时 .pkg 里面只会携带它们的运行期依赖，不会携带构建期依赖
export PKG_PATH="/opt/pkgsrc/packages/All"
pkg_add pkgin mozilla-rootcerts

# 预置 ssl 证书到 .pkg 目录中，随包分发
mozilla-rootcerts install

# 整体进行一遍代码签名
find /storage/Users/currentUser/.pkg -type f | while read -r FILE; do
    if file -b "$FILE" | grep -iqE "ELF|shared object"; then
        echo ">>> Signing: $FILE"
        binary-sign-tool sign -inFile $FILE -outFile $FILE -selfSign 1
        chmod 0755 $FILE
    fi
done

# 改 pkgin 的配置文件，把默认源设置成 github 链接，并使用 ghfast.top 作为镜像站
REPO_URL="https://ghfast.top/https://github.com/pkgsrc-ohos/packages_2025Q4_arm64/releases/download/pkg_summary"
CONF_FILE="/storage/Users/currentUser/.pkg/etc/pkgin/repositories.conf"
echo $REPO_URL > $CONF_FILE

# 删除多余的状态文件
#rm -r /storage/Users/currentUser/.pkg/pkgdb.refcount

# 临时编译一个 zip，用来打包 zip 格式的 bootstrap kit
# 为保障 bootstarp kit 干净，这里没有用 pkgsrc 里面的 zip，而是自己另拿源码编一个
cd $WORKDIR
curl -fSLO https://downloads.sourceforge.net/project/infozip/Zip%203.x%20%28latest%29/3.0/zip30.tar.gz
tar -zxf zip30.tar.gz
cd zip30
bmake -f unix/Makefile install BINDIR=/bin

# 打包
cd $WORKDIR
tar -zcf "bootstrap-ohos-2025Q4-arm64-$(date +%Y%m%d).tar.gz" -C / storage/Users/currentUser/.pkg
cd /
zip -ryX "$WORKDIR/bootstrap-ohos-2025Q4-arm64-$(date +%Y%m%d).zip" storage/Users/currentUser/.pkg
