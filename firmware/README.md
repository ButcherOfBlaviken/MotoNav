# 通用圆屏固件

iOS 与 Android 共用同一份 7.12.0 圆屏固件，源码为 `boards/175/MotoNav`。两边导航协议兼容；Android 使用 App 媒体控制，iOS 使用 HID/AMS。切换手机时按 BLE 说明重新配对，由手机 App 同步设置。手机端 APK 与 IPA 单独下载。

当前发布支持 Waveshare ESP32-S3-Touch-AMOLED-1.75（466×466）。安装 Arduino CLI 与 ESP32 Core 3.3.10 后，从仓库根目录执行：

```sh
python3 firmware/build.py
```

Windows 也可以使用 `./firmware/build.ps1 -Board 175`（PowerShell）。产物均位于 `firmware/dist/175/panel0`，包括应用升级镜像、完整安装镜像和 SHA-256 清单。

将 Release 的通用固件 ZIP 解压到仓库，保留 `firmware/dist/175/panel0` 目录结构。在 Mac 双击根目录 `一键烧录固件.command`，或先执行：

```sh
./一键烧录固件.command --check
```

`--check` 只检查工具、镜像校验与串口，不刷写设备。默认应用升级写入 `0x10000`，要求设备已有相同 16 MB / app3M_fat9M_16MB 分区，不执行整片擦除。首次完整安装可追加 `--full`，写入 `0x0`，需输入 INSTALL 确认，可能影响原设置，请先备份。

发布包使用 `universal` 标识通用固件，与 APK/IPA 区分。清单中 `deviceTested: false` 表示本次重新打包的产物尚未刷入设备实测；源码的历史验证范围见 iOS 说明。编译与协议测试不代替实际道路及设备验证。
