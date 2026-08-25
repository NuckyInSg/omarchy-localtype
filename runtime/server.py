#!/usr/bin/env python3
import io
import json
import logging
import os
import threading
import time
import uuid
from logging.handlers import RotatingFileHandler
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from prompt_defaults import DEFAULT_POLISH_PROMPT
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

STATE_HOME = Path(
    os.environ.get(
        "LOCALTYPE_STATE_HOME",
        Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "localtype",
    )
)
PIPELINE_LOG_PATH = Path(
    os.environ.get("LOCALTYPE_PIPELINE_LOG", STATE_HOME / "pipeline.jsonl")
)
PIPELINE_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
pipeline_logger = logging.getLogger("localtype.pipeline")
pipeline_logger.setLevel(logging.INFO)
pipeline_logger.propagate = False
if not pipeline_logger.handlers:
    pipeline_handler = RotatingFileHandler(
        PIPELINE_LOG_PATH,
        maxBytes=5 * 1024 * 1024,
        backupCount=3,
        encoding="utf-8",
    )
    pipeline_handler.setFormatter(logging.Formatter("%(message)s"))
    pipeline_logger.addHandler(pipeline_handler)

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
SETTINGS_PATH = Path(
    os.environ.get(
        "LOCALTYPE_SETTINGS",
        Path.home() / ".config/localtype/settings.json",
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


def polisher_prompt_template() -> str:
    template = DEFAULT_POLISH_PROMPT
    try:
        settings = json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
        configured = settings.get("polish_prompt") if isinstance(settings, dict) else None
        if isinstance(configured, str) and configured.strip():
            template = configured
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return template


def polisher_messages(template: str, context: str, transcript: str) -> tuple[list[dict], str]:
    try:
        prompt = json.loads(template)
    except json.JSONDecodeError:
        prompt = None
    if isinstance(prompt, dict) and isinstance(prompt.get("system"), str):
        messages = [
            {"role": "system", "content": prompt["system"].replace("{context}", context)}
        ]
        examples = prompt.get("examples", [])
        if isinstance(examples, list):
            for example in examples[:12]:
                if not isinstance(example, dict):
                    continue
                source = example.get("input")
                target = example.get("output")
                if isinstance(source, str) and isinstance(target, str):
                    messages.extend(
                        [
                            {"role": "user", "content": source},
                            {"role": "assistant", "content": target},
                        ]
                    )
        messages.append({"role": "user", "content": transcript})
        return messages, "chat_json"
    return [
        {"role": "system", "content": template.replace("{context}", context)},
        {"role": "user", "content": transcript},
    ], "plain_text"


def write_pipeline_log(payload: dict) -> None:
    event = {"timestamp_ms": round(time.time() * 1000), **payload}
    pipeline_logger.info(json.dumps(event, ensure_ascii=False, separators=(",", ":")))


def polish_text(raw_text: str, context: str, diagnostics: dict | None = None) -> str:
    details = diagnostics if diagnostics is not None else {}
    dictionary_corrected_text = raw_text
    for spoken, written in personal_dictionary().items():
        dictionary_corrected_text = dictionary_corrected_text.replace(spoken, written)
    details.update(
        {
            "dictionary_text": dictionary_corrected_text,
            "polisher_invoked": False,
            "polisher_candidate": None,
            "fallback_reasons": [],
        }
    )
    details["polisher_invoked"] = True
    prompt_template = polisher_prompt_template()
    details["polish_prompt"] = prompt_template
    messages, prompt_format = polisher_messages(
        prompt_template,
        context,
        dictionary_corrected_text,
    )
    details["polish_prompt_format"] = prompt_format
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
    details["polisher_candidate"] = polished

    # A tiny model may occasionally summarize too aggressively or expand the
    # dictation. Fall back to the ASR text instead of risking lost information.
    fallback_reasons = []
    if not polished:
        fallback_reasons.append("empty_candidate")
    if len(polished) < len(dictionary_corrected_text) * 0.55:
        fallback_reasons.append("candidate_too_short")
    if len(polished) > len(dictionary_corrected_text) * 1.6:
        fallback_reasons.append("candidate_too_long")
    details["fallback_reasons"] = fallback_reasons
    if fallback_reasons:
        details["decision"] = "fallback_to_dictionary_text"
        details["final_text"] = dictionary_corrected_text
        return dictionary_corrected_text
    details["decision"] = "accepted_polisher_candidate"
    details["final_text"] = polished
    return polished


@app.get("/health")
def health():
    return {
        "status": "ready",
        "asr_model": "Qwen3-ASR-1.7B",
        "polisher_model": polisher_name,
        "pipeline_log": str(PIPELINE_LOG_PATH),
    }


@app.post("/polish")
def polish(text: str = Form(...), context: str = Form("general")):
    request_id = uuid.uuid4().hex[:12]
    started = time.perf_counter()
    diagnostics = {}
    with inference_lock, torch.inference_mode():
        final_text = polish_text(text, context, diagnostics)
    write_pipeline_log(
        {
            "event": "polish",
            "request_id": request_id,
            "context": context,
            "raw_text": text,
            **diagnostics,
            "total_ms": round((time.perf_counter() - started) * 1000),
        }
    )
    return {"raw_text": text, "text": final_text}


@app.post("/transcribe")
async def transcribe(
    audio: UploadFile = File(...),
    smart: bool = Form(True),
    context: str = Form("general"),
):
    request_id = uuid.uuid4().hex[:12]
    request_started = time.perf_counter()
    stage = "audio_decode"
    try:
        data, sample_rate = sf.read(io.BytesIO(await audio.read()), dtype="float32")
        if data.ndim > 1:
            data = np.mean(data, axis=1)
        if data.size == 0:
            raise ValueError("empty recording")
        with inference_lock, torch.inference_mode():
            stage = "asr"
            asr_started = time.perf_counter()
            result = model.transcribe(
                audio=(data, sample_rate),
                language="Chinese",
            )
            asr_ms = round((time.perf_counter() - asr_started) * 1000)
            raw_text = result[0].text.strip()
            diagnostics = {
                "dictionary_text": raw_text,
                "polisher_invoked": False,
                "polisher_candidate": None,
                "fallback_reasons": [],
                "decision": "verbatim_mode",
                "final_text": raw_text,
            }
            polish_started = time.perf_counter()
            if smart:
                stage = "polisher"
                text = polish_text(raw_text, context, diagnostics)
            else:
                text = raw_text
            polish_ms = round((time.perf_counter() - polish_started) * 1000)
        write_pipeline_log(
            {
                "event": "transcribe",
                "request_id": request_id,
                "smart": smart,
                "context": context,
                "audio_ms": round(data.size / sample_rate * 1000),
                "sample_rate": sample_rate,
                "asr_model": "Qwen3-ASR-1.7B",
                "polisher_model": polisher_name if smart else None,
                "asr_ms": asr_ms,
                "polish_ms": polish_ms,
                "raw_text": raw_text,
                **diagnostics,
                "language": result[0].language,
                "total_ms": round((time.perf_counter() - request_started) * 1000),
            }
        )
        return {
            "raw_text": raw_text,
            "text": text,
            "polished": smart and text != raw_text,
            "language": result[0].language,
        }
    except Exception as exc:
        write_pipeline_log(
            {
                "event": "transcribe_error",
                "request_id": request_id,
                "stage": stage,
                "smart": smart,
                "context": context,
                "error_type": type(exc).__name__,
                "error": str(exc),
                "total_ms": round((time.perf_counter() - request_started) * 1000),
            }
        )
        raise HTTPException(status_code=500, detail=str(exc)) from exc
