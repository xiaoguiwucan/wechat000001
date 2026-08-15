# WeChatIngest 开发文档（脱密版）

给其他开发者或另一台机器上的 AI 用。不含真实主机、账号、密码、wxid、域名。  
自己下次接着改，请改用本机的 `docs/DEV-INTERNAL.md`（不入库）。

配套部署见 [DEPLOY-FNOS.md](DEPLOY-FNOS.md)。手机注入见 [install-quanqian.md](install-quanqian.md)、[install-trollfools.md](install-trollfools.md)。

---

## 1. 项目是什么

iOS 微信侧车采集插件 + NAS 知识库。

- 手机：把 `WeChatIngest-<ver>.dylib` 用 TrollStore / TrollFools / 全能签注入 `com.tencent.xin`。
- 插件：静默记录已勾选的群 + 全部私聊（文本/图/语音/视频/红包/撤回/公告/文件），经 SFTP 丢到 NAS inbox。
- NAS：`consumer.py --watch` 入库；Docker 控制台只读查看。
- **永不自动回私聊。** 群里的 @ 回复继续走原来的 PKC，本插件不发送。

目标微信版本：8.0.75 一带。升级微信后若 hook 失效，重新注入同一 dylib；类名变了再改 `tweak/hooks/`。

---

## 2. 硬规则（改代码前先读）

1. 禁止私聊自动回复，禁止在 DM 上走发送路径。`policy/send_gate.py`、`tweak/hooks/SendGate.m`、`scripts/check-no-dm-send.sh` 卡住。
2. 群回复只走 PKC。本仓库不替代 PKC，两个 dylib 一起注入。
3. 未知微信类型写成 `raw`，不要丢消息。
4. 不在手机上解 wxgf。silk / wxgf 在 NAS 解。
5. 控制台是只读查看器，不能从网页发微信。
6. 产物版本化：`build/WeChatIngest-<ver>.dylib`。控制台 `VERSION` 在 `console/app.py`。
7. 公开仓库不得写入真实密码、token、私人域名、自己的 wxid。

---

## 3. 仓库地图

```text
tweak/                  iOS dylib（ObjC runtime swizzle，不链 CydiaSubstrate）
  Tweak.m               构造函数入口，注册 hook
  Settings.m / .h       NSUserDefaults 套件
  hooks/
    MessageHooks.m      CMessageMgr AddMsg / PreAdd / AppMsg
    MediaExtract.m      从 wrap / 磁盘抠图音视频
    SftpInboxClient.m   libssh2 SFTP 丢 inbox
    NetworkPath.m       Wi-Fi / 蜂窝切换、防闪退
    UploadHUD.m         漫画风悬浮胶囊
    UploadStats.m       今日流量统计
    SettingsUI.m        我 → 插件 → 微信记忆
    SendGate.m          发送闸门
    OpenClawReply.m     预留，默认不发私聊
    Contacts.m          通讯录备注
    DebugLog.m          手机调试日志
store/                  NAS 入库
  consumer.py           inbox → 群聊/私聊 jsonl + 索引.sqlite
  media.py              媒体落盘与目录
  history_map.py        爱思 dump Type → msg_type
  import_ais_dump.py    离线全量导入
  transcribe.py         silk → wav（可选 ASR）
  readable.py           给人看的 md
  cli.py                命令行查询
  schema.sql / event.schema.json
console/                只读网页
  app.py                stdlib HTTP，Basic + session
  static/index.html     微信风会话界面
  Dockerfile / docker-compose.yml
policy/                 采集 / 回复策略（单测锁死「不回私聊」）
deploy/                 systemd / 用户态安装脚本
scripts/build-dylib.sh  Mac 上打 arm64 dylib
third_party/ios-arm64/  预编译 libssh2 + mbedtls
```

当前插件版本见 `tweak/hooks/SettingsUI.m` 的 `WXIngestPluginVersion` 和 `scripts/build-dylib.sh` 的 `VERSION`。  
当前控制台版本见 `console/app.py` 的 `VERSION`。

---

## 4. 端到端数据流

```text
微信 CMessageMgr
    → MessageHooks 映射类型
    → MediaExtract 抽文件（Img/Audio/Video/OpenData）
    → SftpInboxClient 写 NAS/<root>/待入库/<uuid>.json [+ 同名媒体]
    → consumer.py --watch
         校验 / 归一化
         追加 群聊|私聊|公众号/<会话名>/消息.jsonl
         媒体进 图片/语音/视频/文件
         UPSERT 索引.sqlite  UNIQUE(chat_id, msg_id)
    → console 读 jsonl 尾巴 + sqlite
         /api/chats  /api/chats/{kind}/{folder}/messages
         /media/...  silk 现场转 wav，wxgf 尝试出预览
```

事件字段见 `store/event.schema.json`。必填：`chat_id, chat_kind, msg_id, msg_type, sender, ts`。

`msg_type` 枚举：

| 值 | 含义 |
|---|---|
| text | 文本 |
| image | 图片 |
| voice | 语音 silk |
| video | 视频 |
| emoji | 动画表情 |
| file | 文件 |
| redpacket | 红包 |
| revoke | 撤回 |
| announcement | 群公告 / 系统 |
| raw | 未映射（常见：type 49 卡片、50 通话、42 名片、48 位置） |

微信 Type 对照（`store/history_map.py` / `tweak/hooks/MessageHooks.m`）：

| Type | 映射 |
|---|---|
| 1 | text |
| 3 | image |
| 34 | voice |
| 43 / 44 / 62 | video |
| 47 | emoji |
| 49 | 看 XML：6=file，2001=redpacket，4=video，否则 raw |
| 10000 / 10002 | revoke 或 announcement |
| 其它 | raw，`extra_json.raw_type` 保留原值 |

---

## 5. iOS 插件要点

- **注入方式**：adhoc 签名的 arm64 dylib，TrollFools / 全能签注入微信。不越狱、不链 Substrate。
- **Hook**：`method_exchangeImplementations`。目标 `CMessageMgr` 的 `AddMsg:MsgWrap:`、`AsyncOnPreAddMsg:MsgWrap:`、`HandleAppMsg:MsgWrap:`。先调原 IMP 再采集。
- **入口**：微信「我 → 插件 → 微信记忆」。
- **设置套件**：独立 `NSUserDefaults`，不要写进 PKC 的 defaults。
- **网络**：可开内网/外网自动切。切蜂窝时禁止在主线程关 libssh2，必须 debounce 后只在 SFTP 队列重连，否则微信卡死闪退。
- **HUD**：左红右白漫画胶囊，可捏合缩放，统计数字在白区居中。
- **媒体**：默认可只 Wi-Fi 上传；图/语音/视频开关分开；视频有大小上限。
- **历史**：手机不做全量 sqlite 遍历导出（太慢）。全量靠爱思 dump 在 NAS 导入。
- **编译**：

```bash
bash scripts/build-dylib.sh
# -> build/WeChatIngest.dylib
# -> build/WeChatIngest-<VERSION>.dylib
```

需要 Xcode iphoneos SDK。改完版本号同步：`scripts/build-dylib.sh`、`SettingsUI.m`、`Tweak.m` 日志。

---

## 6. NAS 入库要点

生产数据根（示例，部署时改环境变量）：

```text
$WECHAT_INGEST_ROOT/
  待入库/          插件新文件（兼容 inbox/）
  群聊/<会话名>/消息.jsonl
  私聊/<备注>/消息.jsonl
  公众号/
  索引.sqlite
  会话对照.json
  历史记录/        爱思 zip，不要当热数据扫
```

`consumer.py`：

- `UNIQUE(chat_id, msg_id)`，重复投递不会双写。
- 先把 json 改名进 `待入库/.processing/`，成功再删。
- 坏文件进 `待入库/失败/`。
- `--watch` 短间隔轮询，给 systemd 常驻用。

爱思导入 `store/import_ais_dump.py`：

- 表名 `Chat_<md5(username)>`，不要误匹配 `ChatExt2_*`。
- `Des=0` 自己，`Des=1` 对方（dump 约定，和线上 wrap 不一定相同）。
- 媒体按 `MesLocalID` 在 Img/Audio/Video/OpenData 里对上。
- Type 3/34/43/47/49 的 Message 经常是 **zstd dict-id 5**。IPA 里的 `MsgDict.zstd` 是加密的，解不开则 XML 为空，type 49 会变成 `[raw]`。
- 导入会清空 群聊/私聊/索引后重建，不要误清 inbox 以外的热路径时先确认脚本参数。

---

## 7. 控制台要点

- stdlib `ThreadingHTTPServer`，无 pip。
- 登录：HTTP Basic + cookie session。`CONSOLE_USER` / `CONSOLE_PASSWORD` 必须走环境变量。
- 会话列表、状态不要全量扫 200 万行 jsonl：最后一条用文件尾巴；条数用 sqlite `COUNT`。
- 消息接口：默认 80 条，用 `before_ts` + `before_id` 向前翻页。`has_more` 给前端。
- 前端：
  - 视频：大预览卡 + 播放钮，点开灯箱，不要 88×88 内嵌 controls。
  - 语音：点条播放；`.aud` 走 `/media` 时 silk→wav。
  - `[raw]` 按 `raw_type` 显示「语音通话 / 位置 / 名片 / 卡片消息」；挂了 mp3/m4a 的当语音播。
  - 「更早的消息」不要用「limit+=80 且封顶 200」——那会点了没反应。
- 热更新网页：`docker cp console/static/index.html <container>:/app/static/index.html`。
- 热更新 Python：`docker cp app.py` 后 **必须 `docker restart`**。

---

## 8. 给下一任 AI 的开发方式

1. 先读本文件 + `DEPLOY-FNOS.md` + `store/event.schema.json`。
2. 改 UI 只动 `console/static/index.html` 时，改完 docker cp，不要重建镜像也能看。
3. 改入库先补 `store/test_*.py`，再动 `consumer.py`。
4. 改 hook 先看 `contracts/pkc-selectors.json`，再动 `MessageHooks.m`，最后 `scripts/build-dylib.sh`。
5. 任何「代回私聊」需求直接拒绝。
6. 不要把真实密码写进 git。

常用测试：

```bash
python3 -m pytest console/test_app.py store/test_consumer.py store/test_media.py policy -q
```

---

## 9. 已知限制

- `MsgDict.zstd` 未解密 → 约数十万条压缩 XML 没有发送者前缀 / 卡片标题。
- type 50 是通话记录，没有可播录音。
- 部分群文件夹仍可能是 `@chatroom` 数字 id（通讯录里没名字）。
- wxgf 预览在 NAS 尽力而为，失败就显示占位。
- 微信大版本更新后选择子可能失效。

---

## 10. 明确不要做的

- 不要在公开 fork 里提交 `.env`、聊天 jsonl、爱思 zip、微信 IPA。
- 不要再写一套会发消息的机器人到这个 dylib。
- 不要用全表扫描 jsonl 做 `/api/status`。
- 不要在主线程关闭 libssh2 会话。
