# sui2api 与 OpenAI Responses API 差异记录

日期：2026-05-16

## 背景

Sigil 将 `models.json` 中 `api: "openai"` 的 GPT 模型路由到 OpenAI Responses API 兼容 provider。接入 sui2api 时发现：请求能完成、usage 正常、标题生成正常，但 LiveView 没有 assistant 正文。

根因不是 UI，而是 sui2api 的流式 `response.completed` 事件与 OpenAI 官方文档/示例存在差异：最终 completed response 的 `output` 为空，正文只出现在前面的流式事件中。

## 参考来源

- OpenAI 官方 Responses Streaming API：`stream: true` 时服务端通过 SSE 发送事件。文档列出了 `response.output_text.delta`、`response.output_text.done`、`response.content_part.done`、`response.output_item.done`、`response.completed` 等事件。
  - <https://platform.openai.com/docs/api-reference/responses-streaming/response/completed>
  - <https://platform.openai.com/docs/api-reference/responses-streaming/response/content_part/done?api-mode=responses>
- OpenAI 官方文档说明 `response.output_text.delta` 携带增量文本 `delta`，`response.output_text.done` 携带最终文本 `text`，`response.content_part.done` 携带完成的 content part。

## 实测请求

使用 `~/.sigil/models.json` 中的 sui2api provider：

```json
{
  "baseUrl": "https://sa.tone.pp.ua/v1",
  "api": "openai",
  "model": "gpt-5.4-mini"
}
```

最小请求体：

```json
{
  "model": "gpt-5.4-mini",
  "input": [
    {
      "role": "user",
      "content": "只回复 OK"
    }
  ],
  "max_output_tokens": 16
}
```

## 非流式响应

非流式 Responses 请求返回格式与 OpenAI 官方格式一致，正文在 `output[].content[]` 中：

```json
{
  "id": "resp_...",
  "object": "response",
  "status": "completed",
  "output": [
    {
      "type": "message",
      "role": "assistant",
      "content": [
        {
          "type": "output_text",
          "text": "OK"
        }
      ]
    }
  ],
  "usage": {
    "input_tokens": 20,
    "output_tokens": 2,
    "total_tokens": 22
  }
}
```

结论：非流式路径只要解析 `output[].content[].text` 即可。

## 流式响应

sui2api 的流式事件顺序接近 OpenAI 官方 Responses SSE：

```text
event: response.created
event: response.in_progress
event: response.output_item.added
event: response.content_part.added
event: response.output_text.delta
event: response.output_text.done
event: response.content_part.done
event: response.output_item.done
event: response.completed
```

其中正文会出现在这些事件里：

```text
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"OK",...}

event: response.output_text.done
data: {"type":"response.output_text.done","text":"OK",...}

event: response.content_part.done
data: {"type":"response.content_part.done","part":{"type":"output_text","text":"OK",...},...}

event: response.output_item.done
data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]},...}
```

但最后的 completed response 是：

```json
{
  "type": "response.completed",
  "response": {
    "id": "resp_...",
    "object": "response",
    "status": "completed",
    "output": [],
    "usage": {
      "input_tokens": 20,
      "output_tokens": 2,
      "total_tokens": 22
    }
  }
}
```

## 与 OpenAI 官方语义的差异

| 项目 | OpenAI 官方 Responses 语义 | sui2api 实测行为 |
|------|----------------------------|------------------|
| 非流式 `output` | 包含生成的 output items | 包含生成的 output items，正常 |
| 流式 delta | `response.output_text.delta.delta` 携带增量文本 | 一致 |
| 流式 done | `response.output_text.done.text`、`response.content_part.done.part` 携带最终文本/part | 一致 |
| `response.output_item.done` | item 标记完成，item 中可包含完整 message content | 一致 |
| `response.completed.response.output` | 应作为最终 response 对象读取；官方响应对象的 `output` 表示模型生成的内容项 | sui2api 返回 `output: []`，即使前面已经输出了 message |
| 解析策略 | 可以主要依赖最终 response，也可以消费流式事件 | 不能只依赖最终 completed response，必须累计前置 SSE 事件 |

## 对 Sigil Provider 的要求

OpenAI Responses provider 需要兼容两种情况：

1. 标准路径：`response.completed.response.output` 非空，直接解析最终 response。
2. sui2api 路径：`response.completed.response.output` 为空，使用 streaming accumulator 中保存的内容补齐：
   - `response.output_text.delta.delta`：用于即时 UI delta。
   - `response.output_text.done.text`：作为最终文本兜底。
   - `response.content_part.done.part`：作为完整 content part 兜底。
   - `response.output_item.done.item`：作为完整 output item 兜底。

最终策略：

```text
if completed.response.output 非空:
  使用 completed.response.output
else if stream 中收到 output_item.done:
  用 output_item.done.item 补 completed.response.output
else if stream 中收到 content_part.done:
  构造 assistant message output
else if stream 中收到 output_text.done 或 delta 累计文本:
  写入 completed.response.output_text 兜底
```

## 已落地修复

修复位置：

- `lib/sigil/agent/provider/openai.ex`

新增行为：

- stream accumulator 保存 `output` 与累计 `content`。
- 处理 `response.output_text.done`。
- 处理 `response.content_part.done`。
- 处理 `response.output_item.done`。
- 处理 `response.completed` 时，如果 completed response 的 `output` 为空，则用 accumulator 中的 output/text 补齐。

测试覆盖：

- `test/sigil/agent/provider/openai_test.exs`
  - `keeps sui2api output item when completed response output is empty`

验证命令：

```bash
mix test test/sigil/agent/provider/openai_test.exs \
  test/sigil/agent/message_test.exs \
  test/sigil/agent/turn_test.exs \
  test/sigil/tool/registry_test.exs
```

结果：

```text
57 tests, 0 failures
```

## 后续注意

- 不要只用 `response.completed.response.output` 判断流式最终正文是否存在。
- 对 OpenAI Responses 兼容网关，stream parser 应保留前置事件状态，尤其是 `output_item.done`。
- 如果后续支持 function call streaming，还需要同样累计：
  - `response.function_call_arguments.delta`
  - `response.function_call_arguments.done`
  - 对应的 `response.output_item.done.item`
- 日志中不要打印 API key、Authorization header 或完整 provider config。
