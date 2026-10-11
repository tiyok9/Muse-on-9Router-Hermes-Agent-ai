# Konfigurasi Hermes — keputusan & alasan

Ringkasan keputusan konfigurasi Hermes yang sudah **diuji langsung**, agar tidak
perlu menebak ulang. Semua angka di bawah hasil pengukuran nyata terhadap
9Router PC (`http://localhost:20128`), bukan asumsi.

## Bentuk akhir

```yaml
model:
  default: multi          # preset MoA
  provider: moa
  base_url: http://localhost:20128/v1

moa:
  default_preset: multi
  presets:
    multi:
      reference_models:   # 3 penasihat
        - {provider: custom, model: anti,     enabled: true}
        - {provider: custom, model: codebudy, enabled: true}
        - {provider: custom, model: agnes,    enabled: true}
      aggregator: {provider: custom, model: gemini}   # <- BUKAN salah satu reference
      degraded_reference_policy: loud
      max_tokens: 8192
  aggregator: {provider: custom, model: gemini}       # cermin di top-level

fallback_providers:       # dipakai saat primary gagal (rate-limit/5xx/socket)
  - {provider: custom, model: anti,   base_url: http://localhost:20128/v1}
  - {provider: custom, model: gemini, base_url: http://localhost:20128/v1}
```

## Kenapa aggregator `gemini`, bukan `muse` / `anti`

Diukur dengan payload seukuran prompt aggregator MoA (~27k chars) dan uji
tool-calling (yang sebenarnya dibutuhkan agen):

| Kandidat     | Payload besar | Tool-calling | Latensi | Jadi reference juga? |
|--------------|---------------|--------------|---------|----------------------|
| `muse`       | 5/5           | **0/3** ❌   | ~40 s   | tidak                |
| `muse-spark-1.3` (model asli) | **1/5** ❌ | 0/3 ❌ | ~16 s | –            |
| `anti`       | 5/5           | 3/3          | 3,9 s   | **ya** ⚠️            |
| **`gemini`** | **5/5**       | **3/3**      | **5,2 s** | **tidak** ✅       |
| `antigravity`| 5/7           | 3/3          | 5,7 s   | tidak                |
| `xkiro`      | 3/3           | 3/3          | 3,5 s   | tidak                |

Kesimpulan:

1. **`muse` tidak boleh jadi aggregator** — meski combo-nya sudah pulih (5/5),
   **tool-calling-nya rusak** (0/3, timeout ~98 s). Agen Hermes butuh tool-calling.
2. **`anti` tidak dipakai sebagai aggregator** — `anti` adalah *meta-combo* yang
   isinya 6 sub-combo (`codebudy`, `xkiro`, `agnes`, `harbor`, `antigravity`,
   `gemini`). Kalau `anti` jadi aggregator **sekaligus** reference, sang "juri"
   menilai jawabannya sendiri → **independensi MoA hilang**. Ini sebabnya
   aggregator dipindah ke combo non-reference.
3. **`gemini` dipilih** — stabil, tool-calling sehat, bukan reference,
   context 1M, dan punya 5 model internal untuk failover.

## Kenapa tetap MoA, bukan "permodel saja"

Opsi "langsung ke satu model" dipertimbangkan, tapi ditolak untuk saat ini:
model Muse terbaik (`muse-spark-1.3`) masih **flaky 1/5** pada payload besar.
MoA memberi 3 sudut pandang + aggregator yang stabil; kualitas lebih terjaga
selama aggregatornya benar.

## Fallback

`fallback_providers` diisi `anti` lalu `gemini` (keduanya combo stabil).
Sudah **diuji nyata**: primary sengaja dirusak (`custom/does-not-exist-xyz`) →
Hermes tetap menjawab (`PONG`) lewat fallback, config ter-restore otomatis.
Rantai ini melindungi dari rate-limit / 5xx / socket-close upstream.

## Verifikasi

```
python scripts/hermes-verify-moa.py          # 19 PASS / 0 FAIL
python scripts/hermes-verify-muse-spark.py   # 19 PASS / 0 FAIL
python scripts/hermes-verify-nine-models.py  # 11 PASS / 0 FAIL
```

Verifier MoA membaca aggregator dari env `MOA_AGG` (default `gemini`) dan
**memeriksa independensi** (aggregator ≠ reference).

## Celah yang masih terbuka

- Semua peran lewat satu router lokal (`localhost:20128`) — satu titik gagal.
  Fallback di atas mengurangi, bukan menghapus, risiko ini.
- Akar masalah socket upstream Muse (`502 UND_ERR_SOCKET: other side closed`)
  belum hilang; hanya tertutupi oleh failover.
