# Live Activity 深度后台推送（Tier 2）接入指南

灵动岛 / 锁屏 Live Activity 已经在 **App 存活时**（前台、或刚切走/锁屏的宽限期内）
可用 —— 见 Tier 1。但当你**切到抖音、iOS 把 App 挂起**后，App 自身的代码不再运行、
WebSocket 断开，灵动岛就无法再被 App 刷新。要在那时仍持续更新，**只能用 APNs 的
`liveactivity` 推送**（Apple 唯一支持的途径）。本文档说明需要你提供的凭据，以及
代码里尚未接通的最后一段管线。

> ⚠️ 这一层无法在没有你的 Apple 凭据 + 真机的情况下端到端验证：模拟器拿不到可用的
> Live Activity 推送令牌。下面 Go 侧的 APNs 客户端（`internal/relay/apns`）已写好并有
> 单测，但「真机收到推送」必须由你按本文操作后验证。

## 一、你需要准备的（只有你能做）

1. **付费 Apple Developer 账号**（$99/年）。免费账号无法创建 APNs 密钥 / 启用 Push。
2. **APNs Auth Key**：在 developer.apple.com → Certificates, IDs & Profiles → Keys
   新建一个 Key，勾选 **Apple Push Notifications service (APNs)**，下载 `AuthKey_XXXXXXXXXX.p8`
   （只能下载一次）。记下：
   - **Key ID**（10 位，文件名里那串）
   - **Team ID**（账号右上角 / Membership 里的 10 位）
3. App ID `dev.cchandoff.app` 启用 **Push Notifications** capability。
4. 真机一台（iPhone 14 Pro 及以上才有灵动岛；其余机型走锁屏 Live Activity）。

## 二、iOS 工程改动（需要签名构建，故未提前加入）

1. 新增 `app/ios/Runner/Runner.entitlements`：
   ```xml
   <key>aps-environment</key><string>development</string>   <!-- 上架改 production -->
   ```
   并在 Runner target 的 `CODE_SIGN_ENTITLEMENTS` 指向它、在 Xcode 里勾上 Push 能力。
2. `app/ios/Runner/Info.plist` 已加 `NSSupportsLiveActivities`；如需高频更新可再加
   `NSSupportsLiveActivitiesFrequentUpdates = true`。
3. **取推送令牌**（`LiveActivityController.start` 里补一段）：
   ```swift
   if #available(iOS 16.1, *) {
     Task {
       for await tokenData in activity.pushTokenUpdates {
         let hex = tokenData.map { String(format: "%02x", $0) }.joined()
         // 经一个 EventChannel(dev.cchandoff.app/liveactivity/pushtoken) 发给 Dart
       }
     }
   }
   ```
   （`_activity` 目前存为 `Any?`，取令牌时先 `as? Activity<CCAgentActivityAttributes>`。）

## 三、客户端 → relay 令牌管线（尚未接通，需补）

1. **Dart**：新增 `EventChannel('dev.cchandoff.app/liveactivity/pushtoken')`，把
   `{sid, token, env}` POST 到 relay 新端点 `POST /v1/liveactivity/register`。
2. **relay 端点 + 存储**：仿 `internal/relay/sessions.go` 的 identity 提取，按
   `(identity, sid)` 存令牌（可用内存 + TTL，或在 `internal/relay/store` 加表）。
3. **触发推送**：两种接法（任选）：
   - 让桌面 host 在 `broadcastStatus` 时多发一个 `POST /v1/liveactivity/push {sid, working, text}`，
     relay 收到后查 `(identity, sid)` 的令牌并调用 APNs 客户端；**推荐**，不动 wsbroker。
   - 或在 `internal/relay/wsbroker.go` 里识别 `status`/`reply` 帧后扇出推送（更耦合）。

## 四、把 APNs 客户端接进 relay

`internal/relay/apns` 已就绪。建议从环境变量读凭据并构造一次，复用：
```go
c, err := apns.New(apns.Config{
    KeyID:      os.Getenv("APNS_KEY_ID"),
    TeamID:     os.Getenv("APNS_TEAM_ID"),
    Topic:      "dev.cchandoff.app",          // 客户端自动追加 .push-type.liveactivity
    P8PEM:      p8Bytes,                       // 读 AuthKey_XXXX.p8
    Production: os.Getenv("APNS_ENV") == "production",
})
// 每次状态变化：
_, err = c.Push(ctx, apns.Notification{
    DeviceToken:  token,                       // activity.pushTokenUpdates 的 hex
    Event:        "update",                    // 结束时用 "end"
    ContentState: map[string]any{
        "working":    working,
        "latestText": text,
        "updatedAt":  appleRefSeconds(),       // 见下方日期坑
    },
})
```

### content-state 必须匹配 Swift 的 Codable
键名要与 `CCAgentActivityAttributes.ContentState` 完全一致：`working`、`latestText`、
`updatedAt`。**日期坑**：Swift 默认 `JSONDecoder` 把 `Date` 当作「2001-01-01 起的秒数」
(`.deferredToDate`)，所以推送里 `updatedAt` 要发 `unixSeconds - 978307200`；或更稳妥地把
`ContentState.updatedAt` 改成 `Double`（TimeInterval）以消除歧义。`updatedAt` 目前不在
UI 上显示，改成 `Double` 完全无副作用。

## 五、验证（真机）
1. 真机签名构建（带 Push 能力 + entitlements）。
2. 手机进入某远程会话 → 发一条 prompt 触发 working → 切到别的 App / 锁屏。
3. 从桌面侧（或直接 curl relay 的 push 端点）推送，确认灵动岛/锁屏更新。
4. APNs 返回非 200 时，`apns.Client.Push` 的 error 会带上 Apple 的 `reason`
   （如 `BadDeviceToken`、`TopicDisallowed`、`ExpiredProviderToken`），据此排查。
