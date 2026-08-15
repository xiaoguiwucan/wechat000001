# 全能签注入 WeChatIngest.dylib

产物：`build/WeChatIngest.dylib`（iphoneos arm64）

和 PKC 一起注入同一个微信，不要替换 PKC。NAS 部署见 [DEPLOY-FNOS.md](DEPLOY-FNOS.md)。

## 1. 拷到手机

用隔空投送 / iCloud / 文件 App，把 `WeChatIngest.dylib` 放到「文件」里能看到的位置。

## 2. 全能签注入

1. 打开全能签。
2. 选择 **微信**（`com.tencent.xin`）。
3. 注入 `WeChatIngest.dylib`。
4. 如果 PKC 已经在列表里，保持开启，两个一起勾选。
5. 保存后 **杀掉微信再打开**（必须冷启动）。

## 3. 第一次打开微信

入口：**我 → 插件 → 微信记忆**（和 PKC 同一页）。

第一次打开微信也可能弹出提示。点「打开设置」，或自己走进插件页：

- 打开 **启用全量记录**
- SSH 主机填 NAS 内网 IP，或已经做好端口转发的公网域名
- SSH 端口：内网一般是 `22`，走 frp 时填映射端口
- SSH 用户填 NAS 上跑采集的系统用户
- **填 SSH 密码**
- 远端 inbox 填数据根下的 `待入库`（或兼容的 `inbox`）
- 默认记录全部群 + 全部私聊
- 默认仅 Wi-Fi 上传图片/语音/视频
- 这个插件 **不会回复任何人**

点「测试 SSH 连接」，成功后再去随便一个群发一句测试。

如果弹窗被挡掉：摇一摇 / 再进一次微信，或从「我」页多余行进入设置（能 hook 到「更多」页时会多一行）。

## 4. 服务端

fnOS 上用户 `zkx` 跑采集消费：

```bash
bash /home/zkx/wechat-ingest/deploy/install-user.sh
```

确认：

```bash
ls /home/zkx/wechat-ingest/data/inbox
python3 /home/zkx/wechat-ingest/store/cli.py stats
```

## 5. 不要做的事

- 不要关 PKC 的群触发回复（那是另一条通道）。
- 不要指望这个 dylib 自动回私聊。
- 微信升级后如果不再记录，把同一个 dylib 重新注入即可；如果 WeChat 类变了再找我改 hook。
