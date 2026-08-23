#!/usr/bin/env python3
import io
import json
import os
import threading
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from qwen_asr import Qwen3ASRModel
from transformers import AutoModelForCausalLM, AutoTokenizer


app = FastAPI()
model = Qwen3ASRModel.from_pretrained(
    "Qwen/Qwen3-ASR-1.7B",
    dtype=torch.bfloat16,
    device_map="cuda:0",
    max_inference_batch_size=1,
    max_new_tokens=512,
)
polisher_name = "Qwen/Qwen3-0.6B"
polisher_tokenizer = AutoTokenizer.from_pretrained(polisher_name)
polisher_model = AutoModelForCausalLM.from_pretrained(
    polisher_name,
    dtype=torch.bfloat16,
    device_map="cuda:0",
)
inference_lock = threading.Lock()

POLISHER_SYSTEM_PROMPT = """你是听写文本校对器，不是问答助手，也不是摘要器。
只删除填充词、口吃重复和被说话者立即否定的措辞，并修正明显同音字、标点。
必须保留每一个有效信息点、疑问、语气、专有名词、数字、代码、路径和命令。
禁止概括、缩短、回答问题或添加事实；不确定时保持原文。只输出校对后的完整文本。"""

DEFAULT_PERSONAL_DICTIONARY = {
    "泰普勒式": "Typeless",
    "泰普勒斯": "Typeless",
}
DICTIONARY_PATH = Path(
    os.environ.get(
        "LOCALTYPE_DICTIONARY",
        Path.home() / ".config/localtype/dictionary.json",
    )
)


def personal_dictionary() -> dict[str, str]:
    try:
        value = json.loads(DICTIONARY_PATH.read_text(encoding="utf-8"))
        if isinstance(value, dict):
            return {
                str(spoken): str(written)
                for spoken, written in value.items()
                if str(spoken) and str(written)
            }
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return DEFAULT_PERSONAL_DICTIONARY


def polish_text(raw_text: str, context: str) -> str:
    dictionary_corrected_text = raw_text
    for spoken, written in personal_dictionary().items():
        dictionary_corrected_text = dictionary_corrected_text.replace(spoken, written)

    messages = [
        {
            "role": "system",
            "content": (
                POLISHER_SYSTEM_PROMPT
                + f"\n当前应用是 {context}，它只用于判断书写场景，绝对不要把应用名称写进输出。"
            ),
        },
        {"role": "user", "content": "呃，我明天，不对，是后天上午十点去深圳，然后然后下午见客户。"},
        {"role": "assistant", "content": "我后天上午十点去深圳，然后下午见客户。"},
        {"role": "user", "content": "你帮我看一下这个，嗯，Docker 的日志，看看为什么它启动失败了。"},
        {"role": "assistant", "content": "你帮我看一下 Docker 的日志，看看为什么它启动失败了。"},
        {
            "role": "user",
            "content": "我觉得一种更有、一种更好的方法是用本地模型。它可以结合，呃，大语言模型做纠错。",
        },
        {
            "role": "assistant",
            "content": "我觉得一种更好的方法是使用本地模型。它可以结合大语言模型进行纠错。",
        },
        {
            "role": "user",
            "content": "呃，帮我执行，不对，先不要执行，先看一下 Docker logs，然后检查 git status。",
        },
        {
            "role": "assistant",
            "content": "先不要执行。先查看 Docker logs，然后检查 git status。",
        },
        {"role": "user", "content": dictionary_corrected_text},
    ]
    inputs = polisher_tokenizer.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=False,
        return_tensors="pt",
        return_dict=True,
    ).to(polisher_model.device)
    output = polisher_model.generate(
        **inputs,
        max_new_tokens=256,
        do_sample=False,
        pad_token_id=polisher_tokenizer.eos_token_id,
    )
    polished = polisher_tokenizer.decode(
        output[0][inputs["input_ids"].shape[-1]:],
        skip_special_tokens=True,
    ).strip()

    # A tiny model may occasionally summarize too aggressively or expand the
    # dictation. Fall back to the ASR text instead of risking lost information.
    if (
        not polished
        or len(polished) < len(dictionary_corrected_text) * 0.55
        or len(polished) > len(dictionary_corrected_text) * 1.6
    ):
        return dictionary_corrected_text
    return polished


@app.get("/health")
def health():
    return {
        "status": "ready",
        "asr_model": "Qwen3-ASR-1.7B",
        "polisher_model": polisher_name,
    }


@app.post("/polish")
def polish(text: str = Form(...), context: str = Form("general")):
    with inference_lock, torch.inference_mode():
        return {"raw_text": text, "text": polish_text(text, context)}


@app.post("/transcribe")
async def transcribe(
    audio: UploadFile = File(...),
    smart: bool = Form(True),
    context: str = Form("general"),
):
    try:
        data, sample_rate = sf.read(io.BytesIO(await audio.read()), dtype="float32")
        if data.ndim > 1:
            data = np.mean(data, axis=1)
        if data.size == 0:
            raise ValueError("empty recording")
        with inference_lock, torch.inference_mode():
            result = model.transcribe(
                audio=(data, sample_rate),
                language="Chinese",
            )
            raw_text = result[0].text.strip()
            text = polish_text(raw_text, context) if smart else raw_text
        return {
            "raw_text": raw_text,
            "text": text,
            "polished": smart and text != raw_text,
            "language": result[0].language,
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
