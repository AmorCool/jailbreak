set -e

# roothide specific: 下载 roothide 版 bootstrap（相对 jbroot 结构，含 libroothide.dylib/roothideinit.dylib）
# 官方 rootless bootstrap（/var/jb 前缀）与 jbrand 随机路径机制不兼容
curl -L https://raw.githubusercontent.com/roothide/Dopamine2-roothide/2.x/Application/Dopamine/Resources/bootstrap_1800.tar.zst --output bootstrap_1800.tar.zst
curl -L https://raw.githubusercontent.com/roothide/Dopamine2-roothide/2.x/Application/Dopamine/Resources/bootstrap_1900.tar.zst --output bootstrap_1900.tar.zst
