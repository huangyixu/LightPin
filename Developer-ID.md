# LightPin DMG 站外发行

需要 macOS、完整 Xcode、Apple Developer Program 公司团队及本机持有私钥的 Developer ID Application 证书。DMG 包含 LightPin.app 和“应用程序”拖放入口。包支持 Apple 芯片，最低 macOS 14。构建沿用 Xcode 目标的沙盒与 Hardened Runtime。

## 一次性配置

1. 在 developer.apple.com/account 的 Membership details 确认公司团队和十位 Team ID。先检查团队是否已有可用于发布的证书。在发布 Mac 上运行 `security find-identity -v -p codesigning`，应看到 Developer ID Application、公司名称和对应 Team ID。
2. 申请新的本地证书时，由 Account Holder 登录 Certificates, Identifiers & Profiles。在发布 Mac 上打开“钥匙串访问 → 证书助理 → 从证书颁发机构请求证书”，填邮箱和通用名称，选择存储到磁盘。开发者后台进入 Certificates → + → Developer ID Application，按提示选当前适用的中间证书，上传 CSR。下载 .cer 并双击导入生成 CSR 的同一登录钥匙串。
3. 在“我的证书”展开证书，确认下方有私钥。若由另一台 Mac 生成 CSR，需要由公司按内部流程安全迁移带私钥的加密 .p12。证书、私钥、口令和公证密钥均应由公司控制。
4. 在终端配置以下环境变量，把示例替换为公司真实信息。Bundle ID 一旦对外发布，应在后续版本保持稳定，更新时也沿用同一团队签名。

```sh
export TEAM_ID='你的十位团队ID'
export BUNDLE_ID='com.example.LightPin'
export NOTARY_PROFILE='LightPin-Notary'
xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id '公司团队成员的Apple账号邮箱' --team-id "$TEAM_ID"
```

在 account.apple.com 的“登录与安全 → App 专用密码”生成密码，在终端的隐藏输入提示中填写。Apple 账号须已开启双重认证且能访问该团队。命令校验凭据后存入钥匙串；后续脚本只使用 profile 名称。如果公司采用 App Store Connect API Key，也可用 notarytool store-credentials 的 --key、--key-id 及团队 Key 的 --issuer 创建同名 profile。

## 发布一个版本

在项目根目录运行：

```sh
./scripts/package-dmg.sh
```

如果本机有多张相同团队的有效 Developer ID Application 证书，先将 SIGNING_SHA1 设为选定证书在 find-identity 中的 40 位指纹。每次正式发布前更新 Xcode 工程中的版本或构建号。脚本依次检查证书、公证凭据，归档，签应用，创建并签 DMG，等待 Apple 返回 Accepted，装订票据，再用 stapler、codesign、Gatekeeper 校验。全部成功后输出 dist/LightPin-版本-构建号-arm64.dmg。向用户分发这个文件；私有仓库的 Release 默认仅仓库成员可见。

每次构建的 dist/dmg-release.* 目录保留归档及公证回执，失败时检查终端提示的路径。若 Apple 已收到请求但等待中断，使用回执中的 ID 和 notarytool info 或 log 检查该请求。正式发布前，在另一台 Mac 用浏览器下载 DMG，拖入“应用程序”，验证 Gatekeeper 首次打开、截图授权及旧版覆盖升级。换用公司标识后首次启动可能需要重新授权并产生新的沙盒容器。

[Apple 证书申请](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) · [Apple 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution/) · [公证凭据配置](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
