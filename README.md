# 小店收银 store-pos

轻量便利店收银系统：**Flutter 手机 App + Cloudflare Workers/D1（免费）**。

- 扫条码收银，自动算总价
- 结账后自动扣减库存
- 扫条码入库 / 新建商品
- 离线优先：本地 SQLite 先记账，有网时同步到 Cloudflare，多台手机共享库存
- 支持手机摄像头扫码，也支持蓝牙/USB 扫码枪（相当于键盘输入）

## 目录

```
app/      Flutter 客户端（Android / iOS）
worker/   Cloudflare Worker + D1 数据库
```

## 库存同步设计

库存不直接覆盖，而是记录「库存流水」（销售 -n，入库 +n，盘点调整 ±n）。
每条流水有唯一 id，服务器按 id 去重后累加到商品库存，所以多台手机同时卖货也不会冲掉对方的数据。

## 部署后端（Cloudflare）

```bash
cd worker
npm install
npx wrangler login
npx wrangler d1 create store-pos        # 把输出的 database_id 填进 wrangler.toml
# 表结构会在第一次同步时自动创建（也可手动：npx wrangler d1 execute store-pos --remote --file=schema.sql）
npx wrangler secret put API_TOKEN       # 设一个店铺口令，App 里要填同一个
npx wrangler deploy                     # 得到 https://store-pos.<你的子域>.workers.dev
```

> 国内访问 workers.dev 可能不稳定，建议在 Cloudflare 绑定自己的域名。

## 运行 App

```bash
cd app
flutter create . --platforms=android,ios --org com.storepos   # 首次生成平台目录
flutter pub get
flutter run
```

Android 需在 `android/app/src/main/AndroidManifest.xml` 加相机权限：
`<uses-permission android:name="android.permission.CAMERA" />`
iOS 需在 `ios/Runner/Info.plist` 加 `NSCameraUsageDescription`。

首次打开在「设置」里填服务器地址和店铺口令；不填也能纯离线使用。

## 路线图

- [x] 扫码收银 / 扣库存 / 扫码入库 / 商品管理
- [x] 离线记账 + Cloudflare 同步
- [ ] 销售报表、低库存提醒
- [ ] 导出 Excel 备份
- [ ] 小票打印（蓝牙热敏打印机）
