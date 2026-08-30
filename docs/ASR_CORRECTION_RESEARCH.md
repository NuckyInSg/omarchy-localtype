# LocalType ASR 纠错方案调研与实现

> 调研日期：2026-08-29
> 范围：Typeless / OpenTypeless、上下文偏置、中文 ASR 后纠错、开源实现，以及 LocalType 的本地化落地

## 1. 结论

之前的链路是：把个人词典逐条执行全局 `str.replace`，再让 Qwen3-0.6B 润色。它有三个根本问题：

1. **只有规则命中，没有候选召回**：没有录入“错词 → 正词”就无法处理个人术语；同一个术语的另一种近音错法也无法复用。
2. **替换不看语境**：字符串出现就替换，容易误伤同形词、单词内部和另一个应用中的正常表达。
3. **学习成本高**：用户修改完整句子后还要理解并确认一条规则，和 Typeless 的“照常修改文字”心智不一致。

行业中可靠的方案不是单押某一个纠错模型，而是分层处理：

```text
个人词汇/应用上下文
        ↓
ASR 解码前上下文偏置（提高专名召回）
        ↓
1-best / N-best 假设
        ↓
精确别名 + 拼音/字形候选召回
        ↓
语言模型按整句语义重排或生成纠错
        ↓
数字、URL、路径、命令和语义漂移保护
        ↓
从用户 post-edit 学习
```

LocalType 本次采用这条分层路线，不再把“个人词典”等同于“无条件文本替换”。

## 2. Typeless 到底做了什么

### 2.1 可确认的公开能力

Typeless 的公开帮助文档说明：

- [History & Dictionary](https://www.typeless.com/help/quickstart/history-and-dictionary)：用户在听写后改正一个词时，Typeless 会识别首选拼写并放入词典的 **Auto-added** 分类；也允许只添加一个规范词或短语，不要求用户先猜 ASR 会错成什么。
- [Personalization](https://www.typeless.com/help/quickstart/personalization)：无需设置，随使用逐渐学习正式/随意、简洁/详细等抽象写作模式；可关闭。官方声明学习的是抽象模式，而不是保留消息正文。
- [Dictate](https://www.typeless.com/help/quickstart/dictate)：产品目标是让用户自然说、途中改口，输出可直接发送的文字，并按区域语言变体适配。
- [v0.9.0 Personalized, Smarter](https://www.typeless.com/help/release-notes/macos/personalized-smarter)：再次强调个性化不需要初始化配置。

需要区分**产品行为**和**技术实现**：Typeless 没有公开其声学模型、解码图、N-best、纠错模型或如何跨应用观测 post-edit，不能把营销说明推断成某一种论文算法。

### 2.2 OpenTypeless 的实现

检查 OpenTypeless 仓库提交 `cc1b2198437f64efadf561be63166f87c392ad13`：

- `dictionary` 保存规范词和可选 pronunciation；`correction_rules` 保存 pattern/replacement。
- 运行时把规范词和启用的纠错规则加入 LLM prompt。
- Prompt 明确要求规则只在上下文合适时使用，不能盲目替换。
- 其竞争路线图提出 repeated edits、low-confidence segments、dictionary suggestions 和 correction learning，但当前代码没有实现自动建议/自动学习闭环。

因此，OpenTypeless 值得采用的是“**规范词与纠错规则分开、交给上下文判断**”，而不是照搬其尚未落地的路线图。

## 3. 论文中的主流路线

### 3.1 解码前：上下文偏置 / 热词

- Pundak et al., [Deep Context: End-to-end Contextual Speech Recognition](https://arxiv.org/abs/1808.02480)（CLAS）：把一组上下文短语编码后供端到端 ASR 注意，在推理时支持训练阶段未见的 OOV 词；论文报告相对 WER 最多下降 68%。
- 工程上常见的另一类做法是 trie / WFST / context graph，在 beam search 中给匹配热词的 token 路径加分。它比识别后替换更接近声学证据，但偏置过强会产生“没说也出现热词”的误召回。

对 LocalType 的含义：Qwen3-ASR 的 `transcribe(context=...)` 已提供系统上下文入口，应只传**规范拼写**，并写明“发音与上下文吻合时才采用”；不能把已知错词也放进 ASR 上下文。

### 3.2 解码后：N-best + 语言模型纠错

- Chen et al., [HyPoradise](https://arxiv.org/abs/2309.15701)：发布 33.4 万组 N-best/参考文本，LLM 生成式纠错可以超过只从 N-best 中重排的 oracle 上界，因为它还能生成候选列表中缺失的词。
- Yang et al., [Generative Speech Recognition Error Correction with LLMs and Task-Activating Prompting](https://arxiv.org/abs/2309.15649)：few-shot/task-activating prompt 与微调结合，在跨域任务上可优于传统 domain LM rescoring。
- [Can Generative Large Language Models Perform ASR Error Correction?](https://arxiv.org/abs/2307.04172)：比较 constrained N-best selection 和 unconstrained generation，说明生成能力有收益，但也引入内容漂移风险。

对 LocalType 的含义：当前 `qwen-asr==0.0.6` 的高层 API 只返回最终文本，不暴露 N-best 或 token posterior，因此本版使用“1-best + 候选数据 + LLM”。如果后续 ASR backend 暴露 N-best，应把多个声学假设一起交给纠错器，而不是通过多次随机转写伪造 N-best。

### 3.3 中文：必须利用拼音，但不能只看拼音

- [Pinyin Regularization in Error Correction for Chinese Speech Recognition with LLMs](https://arxiv.org/abs/2407.01909)：在 72.4 万组 ChineseHP 上，给 prompt 加入拼音可稳定提升中文 ASR 纠错。
- [Large Language Model Should Understand Pinyin for Chinese ASR Error Correction](https://arxiv.org/abs/2409.13262)：Pinyin-enhanced GEC 与文本/拼音多任务训练在 AISHELL-1、Common Voice 上优于纯文本输入。
- [PERL](https://arxiv.org/abs/2412.03230)：同时融合语义和拼音表示，并用长度约束抑制生成漂移。

共同结论是：**拼音负责召回，语义负责决策，长度/内容约束负责兜底**。仅凭拼音相同直接替换，会把正常同音词改坏。

### 3.4 通用中文拼写纠错不是完整答案

- [Soft-Masked BERT](https://arxiv.org/abs/2005.07421) 将错误检测与字符纠正分开，是中文 CSC 的代表方法。
- [pycorrector](https://github.com/shibing624/pycorrector) 集成 KenLM、MacBERT4CSC、ERNIE-CSC、T5 和 Qwen 系纠错模型，也支持音似/形似混淆集。

这些项目适合书面错别字，但通用 CSC 通常缺少声学/N-best 信息，对代码、路径、中英混合专名也可能过纠。LocalType 已常驻一个 0.6B 本地语言模型，在 8 GiB 显存目标上再常驻一套 MacBERT/CTC 模型并不是当前收益最高的选择。优先把 ASR context、拼音召回、语义重排和 guard 做完整。

## 4. 开源项目的工程做法

| 项目 | 做法 | 对 LocalType 的启发 |
|---|---|---|
| [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | `transcribe` 接受每条音频的 context | 在第一遍识别前传规范词；这是提示式 contextual bias，不等同于可调权重的 WFST |
| [FunASR](https://github.com/modelscope/FunASR) | 模型级 hotword；后处理把显式映射和 target-only 模糊词分开；模糊匹配使用 `pypinyin` + `rapidfuzz`，默认阈值 0.85 | 规范词本身即可召回中文近音错误；显式规则和模糊候选应分层 |
| [WeNet](https://github.com/wenet-e2e/wenet) | context graph / hotword scorer | 真正解码时偏置应由图和分数控制，并评估热词误召回 |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 支持全局及 per-stream hotwords、hotword score，也已支持 Qwen3-ASR hotwords | 将来切换 backend 时保留“每次听写动态词表”接口，不把词表写死在模型实例 |
| [pycorrector](https://github.com/shibing624/pycorrector) | 候选检测 + 统计/神经纠正，多种 CSC/CTC 模型 | 可作为离线评测基线，不直接用通用模型覆盖个人专名 |
| [OpenTypeless](https://github.com/tover0314-w/opentypeless) | 规范词、pronunciation、纠错规则进入 LLM prompt，并要求按语境使用 | 不做全局 `replace`；词汇是候选数据，不是指令 |

## 5. 本次落地

### 5.1 新链路

1. **ASR 前规范词偏置**：`runtime/vocabulary.py::asr_context` 只发送 canonical spelling；同应用学到的词和重复出现的词优先。
2. **候选生成**：
   - 已学 alias 精确命中；
   - 中文规范词/alias 用 Pinyin 窗口匹配，阈值 0.85；
   - 英文产品名忽略空格、连接符和大小写做字形匹配；
   - 候选最多 12 条，避免小模型 prompt 被大词典淹没。
3. **分级决策**：不再执行无条件全局 `str.replace`。同应用已确认、重复确认或具有跨文字专名结构的精确 alias 可做边界安全的确定性修正；其余规范词与拼音/字形候选以有界 JSON 数据加入 Qwen3-0.6B system message，由整句语义重排。
4. **确定性 guard**：生成结果若过长/过短、长句相似度过低，改变疑问意图，或丢失/凭空新增数字、快捷键、URL、邮箱、路径、命令参数、代码 token，则回退经过高置信 alias 修正的 ASR 文本。
5. **自然学习**：用户只需像平常一样修改完整句子并点“学习纠错”或按快捷键；单个、局部、锚点充分的修改会直接学习，不再要求第二次确认。有歧义、多处修改和大改写仍进入审核；连续两次给出同一局部修改后自动升级。
6. **词典心智调整**：新增词时只填“词语或短语”即可，可选填近似读音；这与 Typeless 的 canonical-word dictionary 一致，并保留旧 alias → canonical 数据兼容。

### 5.2 声学纠错记忆

用户纠错不仅产生 `错误文本 → 规范文本`，还可以产生一条 query-by-example 声学样本：

1. 声学学习开启时，历史记录只循环保留最近 20 条完整 WAV；默认关闭。
2. 文本 diff 给出被修改字段及字符区间。
3. `Qwen3-ForcedAligner-0.6B` 把修改前文本对齐到原始音频，以前后未改文字作为隐式锚点，截取字段音频并加少量边界 padding。
4. 长期只保存纠错词语的 FLAC、MFCC+delta 特征和元数据；每个规范词最多 5 个发音原型。
5. 下一次先由精确 alias、拼音或字形生成文本候选，再把候选时间区间与同一规范词的原型做 DTW；只有文本/拼音证据和音频阈值同时通过，才允许确定性修正。
6. 音频匹配不能区分真正同音词，因此不会替代整句语义；也不会在没有文本候选时独立做全音频滑窗替换。

这属于“声学确认”阶段。后续积累足够样本后，可以再加入 speaker-invariant acoustic word embedding、ANN 粗召回和滑窗 DTW 精排，实现文本 1-best 完全偏离时的音频独立召回。

当前 Qwen3-ASR 高层 API 仍不返回 N-best/token score，因此暂时无法实现完整的
`声学分数 + 解码概率 + 个性化偏置 + LM 分数` 联合重排。接口开放后，声学记忆应作为额外 bias，而不是覆盖原始解码概率。

### 5.3 为什么仍保留人工修改动作

Typeless 的公开文档能确认“改完后自动加入”，但没有公开跨应用观测机制。Omarchy/Wayland 没有 macOS Accessibility/Windows UI Automation 那样的通用可编辑文本事件 API。后台记录全局键盘或主动读取输入框既不可靠，也不符合本项目隐私边界。

因此 LocalType 不要求用户**构建规则**，但仍需要一个明确的“这句话是我改好的”信号。现有全句选择快捷键和 History 编辑器就是这个信号；之后的对齐、候选抽取、是否自动学习和 ASR 偏置全部自动完成。

### 5.4 vLLM 流式识别实测与参数

Qwen3-ASR 0.0.6 的原生 streaming state 只支持 vLLM。LocalType 使用 `vllm==0.14.0`、`torch==2.9.1`，每 500 ms 发送一段 16 kHz 单声道 S16 PCM；模型内部每积累 1 秒执行一次增量解码。前 4 个解码块不复用前缀，之后回滚末尾 5 个 token 再生成，因此 UI 必须接受句尾修订，不能用退格模拟普通键盘输入。

RTX 5070 Laptop 8 GiB 上的可用配置是：`gpu_memory_utilization=0.62`、`max_model_len=4096`、`max_num_seqs=1`、`max_num_batched_tokens=512`、`enforce_eager=true`。实测数据：

- vLLM ASR 空载约 4.95 GiB；同时加载 Qwen3-0.6B 后约 6.52 GiB；持续执行 16.9 秒流式与最终识别后，两进程稳定约 7.18 GiB、整卡约 7.27 GiB，剩余约 0.88 GiB。
- Triton 首次全新编译曾耗时 86 秒；缓存建立后，新进程第一次 streaming decode 约 2–10 秒。服务启动时主动用 1 秒静音预热，避免把这段延迟留给第一次听写。
- 预热后的每个 1 秒增量解码约 0.12–0.23 秒；16.9 秒完整 WAV 的 vLLM ASR 约 0.86 秒，包含最终 Polish 的 `/transcribe` 请求约 1.65 秒。

实测还发现，原生 streaming 的 `context` 更接近“前文文本”：把“可能出现的个人词汇”整段提示传入时，静音段会复述词表，长句中也可能把词表插入正文。因此临时 session 不传词汇提示；个人规范词偏置只用于停止后的完整 WAV 最终识别，以正确性优先于临时卡片中的专名拼写。录音器还以低阈值 RMS 门控前导静音，并保留 500 ms pre-roll，避免用户尚未开口时显示静音幻觉；开口后不裁剪停顿，完整 WAV 更始终不受门控影响。

流式结果只更新临时 `partial_text`，流水日志仅记录字符数、回滚位置和延迟，不记录临时正文。停止录音后 session 被取消，完整 WAV 仍独立执行一次最终 ASR、声学候选确认和单次 Polish；只有最终文本写入历史并提交目标应用。流式模式不提供时间戳，ForcedAligner 仍只处理最终完整录音。

## 6. 评测要求

不能只看几个演示句。后续固定评测集至少分为：

- 普通中文同音错误；
- 人名、产品名、英文缩写和中英混合；
- 数字、日期、版本号、URL、路径、CLI 命令；
- 不应修改的正确句（专门衡量 over-correction）；
- 不同应用 class；
- 同一规范词的未见近音变体。

核心指标：

- 全集 CER / 字准确率；
- named-entity recall 与 exact spelling accuracy；
- false correction rate（正确文本被改坏的比例）；
- protected-token preservation；
- 用户 post-edit 次数；
- ASR、候选生成、LLM、总延迟 P50/P95。

发布门槛应同时要求“错误减少”和“误改不上升”。只报告 CER 下降而不报告 over-correction，不足以判断桌面听写是否更可信。

## 7. 后续优先级

1. 收集本机匿名关闭的 before/after fixture（由用户主动导出），建立 100–300 条中文听写回归集。
2. 若 Qwen3-ASR API 暴露 N-best/token score，升级为声学分数 + 拼音 + LLM 联合重排。
3. 给 learned correction 增加真正的 per-app/global scope 和撤销最近学习。
4. 有足够真实 post-edit 后，再评估 LoRA 微调 Qwen3-0.6B 或专用 0.5–1.5B ASR-EC 模型；不要先用合成书面错字数据替代真实 ASR 错误分布。
