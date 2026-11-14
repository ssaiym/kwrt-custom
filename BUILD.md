# Kwrt 二开构建指南（Xiaomi AX3000T）

本仓库已按你的需求定制：只构建 `mediatek/filogic` 下的 `xiaomi_ax3000t` 单设备固件，
预装 PassWall2(Xray) + Tailscale + ZeroTier + frpc + WireGuard。
改动位置见 `devices/mediatek_filogic/.config` 末尾。

## 1. 推送到自己的 GitHub 仓库

```bash
cd Kwrt-25.12
git init
git add -A
git commit -m "Kwrt baseline: single-device AX3000T + custom packages"
git remote add origin https://github.com/<你的用户名>/kwrt-custom.git
git branch -M main
git push -u origin main
```

无需配置任何 Secrets。不配 `TOKEN_KIDDIN9` 时仅跳过 Release 上传，固件仍以 Artifact 形式产出。

## 2. 触发构建

GitHub 仓库页面 → Actions → 左侧 **Build OpenWrt** → Run workflow →
target 填 `mediatek_filogic`（默认即是）→ Run workflow。

单设备构建约 1–3 小时。

## 3. 下载固件

构建完成后进入该次 run 的 Artifacts 下载 `xx.xx_mediatek_filogic`，解压后：

- `openwrt-25.12.xx-...-mediatek-filogic-xiaomi_ax3000t-squashfs-sysupgrade.bin` — 在 Kwrt/OpenWrt 系统上升级用
- `...-factory.ubi` — 从小米原厂系统经 U-Boot 刷入用

## 4. 刷入（路由器当前已是 Kwrt 的情况）

1. SSH 备份当前配置：`sysupgrade -b /tmp/backup.tar.gz`，用 SFTP 拉回本地
2. LuCI → 系统 → 备份/升级 → 上传 `sysupgrade.bin`，**首次刷入建议不勾选"保留配置"**
3. 等待 3–5 分钟重启，浏览器访问 `10.0.0.1`（本固件默认 LAN 网段）

注意：AX3000T 仅 128MB 闪存，本固件预装包较多，`rootfs_data` 剩余空间会比原版小，
后续在线装包前先 `df -h` 看空间。

## 5. 迭代二开

改 `devices/mediatek_filogic/.config`（加包）或 `patches/`、`diy/`（改源码）→
commit + push → Actions 里再 Run 一次。包名必须真实存在于
[kiddin9/op-packages](https://github.com/kiddin9/op-packages) 或官方 feeds，
写错会**静默忽略不报错**，出包后进 LuCI 验证是否真的装上了。

## 6. 构建失败排查

Actions 日志定位到首个 ERROR；依赖缺失时改包名或注释掉该包重跑；
镜像过大时（AX3000T 放不下）优先去掉 `Basic_Core_All`、`sing-box` 等大包。

## 7. 本地预览环境（D:\KwrtPreview）

双击 `start-vm.bat` 启动 Kwrt x86 预览虚拟机（TCG 模拟约 3-6 分钟出登录提示）：

- LuCI: <http://127.0.0.1:8080>，账号 `root` / 密码 `root`
- SSH: `ssh -p 2222 root@127.0.0.1`（同账号密码）
- 串口控制台：bat 窗口本身（可直接登录）

预览新功能流程：VM 里 `opkg update && opkg install <包名>` →
浏览器确认界面/配置流程满意 → 把包写进 `devices/mediatek_filogic/.config` →
推送触发正式构建 → 刷真机。

注意事项：
- VM 网关已配置 10.0.0.2（qemu slirp），opkg 可联网；VM 网段必须与
  guest 静态 LAN 10.0.0.1/24 一致（bat 里已固化），改错会导致端口转发静默失效
- 虚拟机里验证的是 LuCI 界面/配置流程/脚本逻辑；MT7981 特有行为
  （无线、硬件加速）以真机为准
- 纯净镜像备份在同目录 `kwrt-x86.pristine.img`，VM 玩坏了就
  `copy /y kwrt-x86.pristine.img kwrt-x86.img` 重来

