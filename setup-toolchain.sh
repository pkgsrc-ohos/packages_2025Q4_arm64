#!/bin/sh
set -e

cd /opt

# 把这些命令行工具预置到容器中
curl -fSLO https://github.com/Harmonybrew/ohos-busybox/releases/download/1.37.0/busybox-1.37.0-ohos-arm64.tar.gz
curl -fSLO https://github.com/Harmonybrew/ohos-git/releases/download/2.45.2/git-2.45.2-ohos-arm64.tar.gz
curl -fSLO https://github.com/Harmonybrew/ohos-gawk/releases/download/5.3.2/gawk-5.3.2-ohos-arm64.tar.gz
curl -fSLO https://github.com/Harmonybrew/ohos-grep/releases/download/3.12/grep-3.12-ohos-arm64.tar.gz
curl -fSLO https://github.com/Harmonybrew/ohos-diffutils/releases/download/3.12/diffutils-3.12-ohos-arm64.tar.gz
curl -fSLO https://github.com/Harmonybrew/ohos-coreutils/releases/download/9.10/coreutils-9.10-ohos-arm64.tar.gz
ls | grep tar.gz$ | xargs -n 1 tar -zxf
ln -sf $(pwd)/*-ohos-arm64/bin/* /bin/

# 把 tar 和 gzip 换成 busybox 的实现，避免出现压缩率不足和压缩过程中崩溃的问题
ln -sf /bin/busybox /bin/tar
ln -sf /bin/busybox /bin/gzip

# 准备 ohos-sdk
sdk_download_url="https://cidownload.openharmony.cn/version/Master_Version/ohos-sdk-public_ohos/20260108_020526/version-Master_Version-ohos-sdk-public_ohos-20260108_020526-ohos-sdk-public_ohos.tar.gz"
curl -fSL -o ohos-sdk.tar.gz $sdk_download_url
mkdir /opt/ohos-sdk
tar -zxf ohos-sdk.tar.gz -C /opt/ohos-sdk
cd /opt/ohos-sdk/ohos
busybox unzip -q native-*.zip

# 把 ld.lld 从软链接的形态改成封装脚本的形态，以实现默认启用链接器签名
#（也就是这个特性：https://gitcode.com/openharmony/third_party_llvm-project/pull/882）
llvm_bin="/opt/ohos-sdk/ohos/native/llvm/bin"
rm $llvm_bin/ld.lld
cat <<EOF > $llvm_bin/ld.lld
#!/bin/sh
exec -a "\$0" $llvm_bin/lld --code-sign "\$@"
EOF
chmod 0755 $llvm_bin/*

# 把 llvm 里面的命令封装一份放到 /bin 目录下，只封装必要的工具
# 必须用这种封装的方案，不能直接软链接过去
essential_tools="clang clang++ clang-cpp ld.lld lldb llvm-addr2line llvm-ar llvm-cxxfilt llvm-nm llvm-objcopy llvm-objdump llvm-ranlib llvm-readelf llvm-size llvm-strings llvm-strip"
for executable in $essential_tools; do
    cat <<EOF > /bin/$executable
#!/bin/sh
exec $llvm_bin/$executable "\$@"
EOF
    chmod 0755 /bin/$executable
done

# 对 llvm 进行软链接，生成 cc、gcc、ld、binutils
cd /bin
ln -s clang cc
ln -s clang gcc
ln -s clang++ c++
ln -s clang++ g++
ln -s clang-cpp cpp
ln -s ld.lld ld
ln -s llvm-addr2line addr2line
ln -s llvm-ar ar
ln -s llvm-cxxfilt c++filt
ln -s llvm-nm nm
ln -s llvm-objcopy objcopy
ln -s llvm-objdump objdump
ln -s llvm-ranlib ranlib
ln -s llvm-readelf readelf
ln -s llvm-size size
ln -s llvm-strip strip

# 清除多余文件
rm -f /opt/*.tar.gz /opt/ohos-sdk/ohos/*.zip
