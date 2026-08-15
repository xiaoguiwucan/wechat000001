---
name: wechat-memory
description: 查询手机微信全量记录（群聊/私聊），回答今天某群发生了什么、生成群日报、搜索历史消息。私聊只在用户明确问起时才检索，默认不写进日报，也绝不建议回复任何人。
user-invocable: true
---

# 微信记忆

微信消息由 iOS 插件 `WeChatIngest.dylib` 静默采集，经 SFTP 落到 fnOS：

```text
WECHAT_INGEST_ROOT=/home/zkx/wechat-ingest/data
CLI=python3 /home/zkx/wechat-ingest/store/cli.py
```

这是证据库，不是 OpenClaw 会话。不要把全天所有群原文一次性塞进上下文。

## 硬规则

- 私聊默认不进日报。只有用户明确问某个人才检索 `dms/`。
- 禁止建议、起草或发送任何私聊自动回复。
- 群回复仍然只走原来的 PKC 触发通道，不要因为读到了记录就去回复群。
- 先用 CLI 检索，再根据命中的 50～200 条做摘要。

## 命令

在 exec 里设置同样的环境变量后执行：

```bash
export WECHAT_INGEST_ROOT=/home/zkx/wechat-ingest/data
python3 /home/zkx/wechat-ingest/store/cli.py stats
python3 /home/zkx/wechat-ingest/store/cli.py list-chats
python3 /home/zkx/wechat-ingest/store/cli.py export --chat 'CHAT_ID' --since UNIX
python3 /home/zkx/wechat-ingest/store/cli.py search '关键词' --kind group --limit 80
python3 /home/zkx/wechat-ingest/store/cli.py digest --date YYYY-MM-DD --kind group
```

`chat_id` 群是 `数字@chatroom`，私聊是对方 wxid。

## 用户可能这样问

- 「今天 xx 群发生了什么」→ `list-chats` 找到 chat_id，再 `export --since` 当天 0 点
- 「做昨天的群日报」→ `digest --date` 昨天
- 「谁提过合同」→ `search 合同 --kind group`
- 「我和张三昨天说了什么」→ 先确认用户在问私聊，再 search/export dm

## 日报写法

按群输出：议题、结论、待办、红包/撤回/公告等特殊事件。引用原文时带发送者和大概时间。媒体消息用 `[图片]` / `[语音]` / `[视频]` 并注明 `media_path` 是否存在。
