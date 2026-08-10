set -e

# roothide specific: 下载 roothide 版 bootstrap（相对 jbroot 结构，含 libroothide.dylib/roothideinit.dylib）
# 官方 rootless bootstrap（/var/jb 前缀）与 jbrand 随机路径机制不兼容
curl -L https://raw.githubusercontent.com/roothide/Dopamine2-roothide/2.x/Application/Dopamine/Resources/bootstrap_1800.tar.zst --output bootstrap_1800.tar.zst
curl -L https://raw.githubusercontent.com/roothide/Dopamine2-roothide/2.x/Application/Dopamine/Resources/bootstrap_1900.tar.zst --output bootstrap_1900.tar.zst
# build38.28: roothide Manager（roothideapp.deb，com.roothide.manager）在 3.x merge 时丢失，
# 导致首次越狱后桌面没有 Manager 图标。从 rh2 同源下载，DOBootstrapper.ensureRoothideManagerInstalled
# 会幂等安装到 jbroot/Applications/。脚本与仓库内文件双保险（仓库内已提交一份）。
curl -L https://raw.githubusercontent.com/roothide/Dopamine2-roothide/2.x/Application/Dopamine/Resources/roothideapp.deb --output roothideapp.deb
