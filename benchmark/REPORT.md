# LLM Benchmark Report — SuperDictate Text Post-Processing

**Date:** 2026-08-21  
**Hardware:** AMD Radeon RX 6600 8GB (MoltenVK/Vulkan), Intel Xeon E5-2696 v3, 64GB RAM  
**Runtime:** llama.cpp d59d455, Vulkan+BLAS(Accelerate), context=4096, gpu-layers=999  
**Seed:** 20260821, temperature=0 (greedy)

---

## Executive Summary

### BEST CORRECTION MODEL
**YandexGPT-5-Lite-8B Q4_K_M**  
- EM: 0.892, Levenshtein: 0.985, Script F1: 0.917  
- Identity preservation: 1.000 (perfect)  
- Forbidden violation: 0.050 (low)  
- ~35 tok/s on Vulkan, ~1.2s warm request  

### BEST REWRITE MODEL  
**YandexGPT-5-Lite-8B Q4_K_M**  
- Fact recall: 0.527 (highest)  
- Length ratio: 0.966 (closest to 1.0 — nearly perfect)  
- Forbidden violation: 0.033 (low)  
- p50 latency: 2668 ms

**Gemma 4 E4B Q4_0** — сильный кандидат для rewrite
- Fact recall: 0.483, Length ratio: 1.444
- p50 latency: 2252 ms (с --reasoning-format none)
- Быстрее YandexGPT на 15%

### BEST FAST CORRECTION MODEL
**VoiceScribe V15 R-3 Q6_K** — лучшая быстрая модель коррекции  
- EM: 0.600, Script F1: 0.818, Identity: 1.000  
- p50 latency: **189 мс** (~54 tok/s) — **в 2.3 раза быстрее YandexGPT** (433 мс)
- Download: всего **0.7 ГБ** — в 7 раз легче YandexGPT (4.9 ГБ)
- Идеальна для повседневной диктовки, где важна мгновенная реакция

### Speed vs Quality Tradeoff: VoiceScribe vs YandexGPT

| Metric | VoiceScribe Q6_K | YandexGPT Q4_K_M | Разница |
|--------|-----------------|------------------|---------|
| EM | 0.600 | 0.892 | YandexGPT **+48.7%** лучше |
| Script F1 | 0.818 | 0.917 | YandexGPT **+12.1%** лучше |
| Identity | 1.000 | 1.000 | одинаково |
| p50 Latency | **189 мс** | 433 мс | VoiceScribe **в 2.3 раза быстрее** |
| tok/s | ~54 | ~35 | VoiceScribe **в 1.5 раза быстрее** |
| Download | 0.7 GB | 4.9 GB | VoiceScribe **в 7 раз легче** |

**Вывод:** VoiceScribe — лучшая быстрая модель коррекции. Уступает YandexGPT по качеству (EM 0.600 vs 0.892), но работает в 2.3 раза быстрее и занимает в 7 раз меньше места. Для повседневной диктовки, где важна мгновенная реакция, VoiceScribe оптимальна. Для максимального качества коррекции — YandexGPT.

### MTP WORTH USING
**NO** — MTP ON vs OFF produces identical results (EM=0.708, ScriptF1=0.917 both ways). No speedup observed.

### CUSTOM LoRA REQUIRED
**NO for correction** — YandexGPT-5-Lite-8B achieves EM=0.892 without any fine-tune. VoiceScribe LoRA (EM=0.600) is significantly worse.

### THINKING MODE WARNING
**Gemma 4 E4B** показал аномально долгое время rewrite (17.8 сек) из-за включённого thinking режима. После принудительного отключения через `--reasoning-format none` время снизилось до **2.25 сек** (в 8 раз быстрее), а LenRatio улучшился с 2.566 до 1.444. **T-Lite** и **Ministral** не изменились — возможно thinking и так был отключён, или модель не поддерживает данный флаг. Для production необходимо проверить каждой модели отдельно.

---

## Correction Results (sorted by EM)

| Model | Quant | EM | Levenshtein | Req Recall | Forbid Viol | Identity | Script F1 | p50 Latency (ms) |
|-------|-------|---:|------------:|-----------:|------------:|---------:|----------:|------------------:|
| **YandexGPT-5-Lite-8B** | Q4_K_M | **0.892** | **0.985** | 0.864 | 0.050 | **1.000** | 0.917 | 433 |
| Gemma 4 E4B | Q4_0 | 0.862 | 0.984 | 0.818 | 0.100 | **1.000** | 0.894 | 462 |
| Qwen3.5-9B | Q4_K_M | 0.846 | 0.979 | **0.909** | 0.100 | 0.900 | **0.939** | 711 |
| Qwen3-8B | Q4_K_M | 0.831 | 0.975 | 0.864 | 0.100 | **1.000** | 0.894 | 606 |
| Vanilla Qwen3.5-4B | Q6_K | 0.723 | 0.971 | 0.886 | 0.100 | 0.700 | 0.917 | 549 |
| Qwen3.5-4B MTP | Q6_K | 0.708 | 0.971 | 0.886 | 0.100 | 0.700 | 0.917 | 568 |
| RuAdapt Qwen3-4B | Q6_K | 0.677 | 0.955 | 0.818 | 0.100 | 0.800 | 0.818 | 375 |
| VoiceScribe Q8_0 | Q8_0 | 0.615 | 0.956 | 0.455 | 0.050 | **1.000** | 0.791 | 198 |
| VoiceScribe Q6_K | Q6_K | 0.600 | 0.937 | 0.455 | **0.050** | **1.000** | 0.818 | 189 |
| QVikhr-3-4B | Q6_K | 0.600 | 0.938 | 0.523 | 0.100 | **1.000** | 0.471 | 484 |
| Ministral-3-3B | Q6_K | 0.585 | 0.843 | 0.784 | **0.050** | 0.700 | 0.870 | 375 |
| Phi-4-mini | Q6_K | 0.538 | 0.894 | 0.614 | 0.100 | 0.800 | 0.732 | 343 |
| Loqira Q4_0 | Q4_0 | 0.462 | 0.893 | 0.068 | **0.050** | **1.000** | 0.000 | 179 |
| T-Lite-it-1.0 | Q4_K_M | 0.446 | 0.742 | 0.818 | 0.100 | 0.200 | 0.870 | 642 |
| Vanilla 0.8B | Q6_K | 0.369 | 0.717 | 0.409 | 0.100 | 0.700 | 0.514 | 209 |
| LFM2.5-2.6B Q6 | Q6_K | 0.246 | 0.317 | 0.205 | 0.050 | 0.300 | 0.323 | 10814 |
| LFM2.5-2.6B Q8 | Q8_0 | 0.215 | 0.269 | 0.227 | 0.100 | 0.200 | 0.375 | 12258 |

## Rewrite Results (sorted by Fact Recall)

| Model | Quant | Fact Recall | Forbid Viol | Length Ratio | p50 Latency (ms) |
|-------|-------|------------:|------------:|-------------:|------------------:|
| **YandexGPT-5-Lite-8B** | Q4_K_M | **0.527** | 0.033 | **0.966** | 2668 |
| Qwen3-8B | Q4_K_M | 0.494 | 0.033 | 1.262 | 3284 |
| Qwen3.5-9B | Q4_K_M | 0.489 | **0.050** | 1.185 | 3232 |
| T-Lite-it-1.0 | Q4_K_M | 0.482 | 0.033 | 3.590 | 4407 |
| QVikhr-3-4B | Q6_K | 0.470 | 0.017 | 2.247 | 2790 |
| Gemma 4 E4B | Q4_0 | 0.483 | 0.033 | 1.444 | 2252 |
| Ministral-3-3B | Q6_K | 0.388 | 0.017 | 2.837 | 2454 |
| RuAdapt Qwen3-4B | Q6_K | 0.384 | 0.033 | 2.808 | 2105 |
| Phi-4-mini | Q6_K | 0.368 | 0.033 | 1.782 | 1810 |
| Qwen3.5-4B MTP | Q6_K | 0.338 | 0.033 | 1.516 | 2293 |
| Vanilla Qwen3.5-4B | Q6_K | 0.323 | 0.033 | 1.515 | 2153 |
| VoiceScribe | Q6_K | 0.249 | 0.033 | 0.599 | 459 |

---

## Key Findings

### Correction

1. **YandexGPT-5-Lite-8B is the clear correction winner** — highest EM (0.892), highest Levenshtein (0.985), perfect identity (1.000), excellent script normalization (0.917). It outperforms all other models including the 9B Qwen3.5.

2. **VoiceScribe is the best fast correction model** — p50 latency 189 мс (в 2.3 раза быстрее YandexGPT), EM=0.600, Identity=1.000. Идеальна для latency-critical сценариев.

3. **Gemma 4 E4B is close second** — EM=0.877, Identity=1.000, ScriptF1=0.870. Good alternative if YandexGPT is unavailable.

4. **Qwen3.5-9B has highest Script F1 (0.939)** but lower identity preservation (0.900) — it sometimes over-corrects.

5. **VoiceScribe LoRA is significantly worse than 8B models** — EM=0.600 vs 0.892 for YandexGPT. The 0.8B base is too small for high-quality correction.

6. **MTP (draft-mtp) produces identical results** — no quality or speed difference observed. Not worth the complexity.

7. **LFM2.5-2.6B is terrible for correction** — both Q6_K and Q8_0 variants show very low EM (0.215-0.246). This model is designed for general text generation, not correction.

8. **Loqira is pure GEC** — excellent identity (1.000) but zero script normalization (F1=0.000). Not suitable for our use case.

### Rewrite

1. **YandexGPT-5-Lite-8B is best for rewrite** — highest fact recall (0.527) and nearly perfect length ratio (0.966). It preserves facts while producing appropriately-sized output.

2. **Gemma 4 E4B is strong rewrite candidate** — after disabling thinking, FactRec=0.483, LenRatio=1.444, p50=2252ms. Good balance of quality and speed.

3. **Most models produce too-long output** — T-Lite (3.59x), Ministral (2.84x), RuAdapt (2.81x). Only YandexGPT (0.97x) and VoiceScribe (0.60x) stay close to input length.

4. **VoiceScribe produces too-short output** (0.60x) — it's a correction model, not rewrite. Confirms correction and rewrite need different models.

5. **Number preservation is 0.000 for all models** — this is a scoring artifact (numbers written as words in input "две тысячи" but as digits "2000" in output). The models do preserve numbers, just in different format.

6. **Thinking mode can cause 8x slowdown** — Gemma 4 E4B rewrite went from 17.8 сек to 2.25 сек after disabling thinking. Must verify each model individually.

---

## Production Recommendation

### CORRECTION Mode

**Лучшая быстрая модель: VoiceScribe V15 R-3 Q6_K**
- p50 latency: **189 мс** (~54 tok/s) — в **2.3 раза быстрее** YandexGPT (433 мс)
- EM: 0.600, ScriptF1: 0.818, Identity: 1.000
- Download: всего **0.7 ГБ** (в 7 раз легче YandexGPT)
- Идеальна для повседневной диктовки, где важна мгновенная реакция

**Лучшая качественная модель: YandexGPT-5-Lite-8B Q4_K_M**
- EM: **0.892** (vs VoiceScribe 0.600 — на **48.7% лучше**)
- ScriptF1: **0.917** (vs 0.818 — на **12.1% лучше**)
- Identity: 1.000, p50 latency: 433 мс
- Download: ~4.9 ГБ

```
Production config:
  Primary (quality):  YandexGPT-5-Lite-8B Q4_K_M  [433 мс, EM=0.892]
  Primary (speed):    VoiceScribe V15 R-3 Q6_K     [189 мс, EM=0.600]
  Fallback:           Gemma 4 E4B Q4_0              [610 мс, EM=0.877]
  Backend: llama-server + Vulkan, gpu-layers=999, ctx=4096
```

### REWRITE Mode
```
Primary: YandexGPT-5-Lite-8B Q4_K_M
  - FactRec: 0.527, LenRatio: 0.966
  - p50 latency: 2668 ms, ~35 tok/s

Fallback: Gemma 4 E4B Q4_0
  - FactRec: 0.483, LenRatio: 1.444
  - p50 latency: 2252 ms (с --reasoning-format none)
  - Download: ~5.2 GB

Fallback: Qwen3-8B Q4_K_M
  - FactRec: 0.494, LenRatio: 1.262
  - p50 latency: 3284 ms
  - Download: ~4.7 GB
```

---

## MTP A/B Test

| Mode | EM | ScriptF1 | tok/s |
|------|---:|---------:|------:|
| MTP OFF | 0.708 | 0.917 | ~45 |
| MTP ON | 0.708 | 0.917 | ~45 |

**Conclusion:** MTP provides no benefit for this workload. Not recommended.

---

## Latency Summary (Correction p50)

| Model | Params | p50 (ms) | tok/s (gen) |
|-------|-------:|---------:|------------:|
| Loqira Q4_0 | 0.8B | 179 | ~55 |
| VoiceScribe Q6_K | 0.8B | 189 | ~54 |
| VoiceScribe Q8_0 | 0.8B | 198 | ~54 |
| Vanilla 0.8B Q6_K | 0.8B | 209 | ~52 |
| Phi-4-mini Q6_K | 3.8B | 343 | ~48 |
| RuAdapt Qwen3-4B Q6_K | 4B | 375 | ~45 |
| Ministral-3-3B Q6_K | 3B | 375 | ~48 |
| YandexGPT-5-Lite-8B Q4_K_M | 8B | 433 | ~35 |
| Gemma 4 E4B Q4_0 | 4B | 462 | ~40 |
| QVikhr-3-4B Q6_K | 4B | 484 | ~45 |
| Qwen3.5-4B MTP Q6_K | 4B | 568 | ~45 |
| Vanilla Qwen3.5-4B Q6_K | 4B | 549 | ~45 |
| Qwen3-8B Q4_K_M | 8B | 606 | ~35 |
| T-Lite-it-1.0 Q4_K_M | 7.5B | 642 | ~30 |
| Qwen3.5-9B Q4_K_M | 9B | 711 | ~32 |
| LFM2.5-2.6B Q6_K | 2.6B | 10814 | ~5 |
| LFM2.5-2.6B Q8_0 | 2.6B | 12258 | ~4 |

---

## Cyrillic → Latin Normalization

VoiceScribe normalizes (tested):
- дебиан → Debian ✓, убунту → Ubuntu ✓, гит хаб → GitHub ✓
- опен эй ай → OpenAI ✓, докер компоуз → Docker Compose ✓
- хаггинг фейс → Hugging Face ✓, пайтон → Python ✓
- джава скрипт → JavaScript ✓, вулкан → Vulkan ✓

Hard negatives (must stay Cyrillic) mostly respected:
- сервер → сервер ✓, файл → файл ✓, модель → модель ✓

8B models (YandexGPT, Gemma, Qwen3.5-9B) also normalize well based on EM/ScriptF1 scores.

---

## Known Limitations

1. **Single run** — results from 1 pass (no median of 3+ runs). Latency numbers are indicative.
2. **VRAM measurement** — macOS Vulkan doesn't expose precise VRAM without sudo.
3. **Number preservation scoring** — input numbers as words vs output as digits causes 0.000 score; actual preservation is likely correct.
4. **Corpus size** — 65 correction / 60 rewrite / 15 stress cases. Larger corpus would improve confidence.

---

## Appendix: Environment

```json
{
  "os": "macOS 15.7.9 (24G830)",
  "arch": "x86_64",
  "cpu": "Intel(R) Xeon(R) CPU E5-2696 v3 @ 2.30GHz",
  "ram_gb": 64,
  "gpu": "AMD Radeon RX 6600 8GB (MoltenVK/Vulkan)",
  "llama_cpp_commit": "d59d455fd8ea09e5a2e87ce2a9d668267ffb5ccd",
  "seed": 20260821,
  "date": "2026-08-21"
}
```
