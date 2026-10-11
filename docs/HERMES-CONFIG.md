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
        - {provider: custom, model: anti,  enabled: true}
        - {provider: custom, model: muse,  enabled: true}
        - {provider: custom, model: agnes, enabled: true}
      aggregator: {provider: custom, model: codebudy}  # <- BUKAN salah satu reference
      degraded_reference_policy: loud
      max_tokens: 8192
  reference_models: [anti, muse, agnes]                # cermin di top-level
  aggregator: {provider: custom, model: codebudy}      # cermin di top-level

fallback_providers:       # dipakai saat primary gagal (rate-limit/5xx/socket)
  - {provider: custom, model: anti,   base_url: http://localhost:20128/v1}
  - {provider: custom, model: gemini, base_url: http://localhost:20128/v1}
```

## Pembagian peran: aggregator butuh tool-calling, reference tidak

Ini pembeda paling penting:

- **Aggregator = aktor.** Ia yang memegang tool, menjalankan perintah, dan
  menyusun jawaban akhir ke user. Ia **wajib** bisa tool-calling.
- **Reference = penasihat teks.** Prompt sistemnya eksplisit melarang
  mengeksekusi apa pun ("You are NOT the acting agent and you do NOT execute
  anything"). Jadi tool-calling **tidak relevan** untuk reference — cukup
  menghasilkan analisis teks.

Konsekuensinya: model dengan tool-calling lemah masih layak jadi **reference**,
tapi tidak layak jadi **aggregator**.

## Kenapa aggregator `codebudy`

Diukur dengan payload seukuran prompt aggregator MoA (~27k chars) dan uji
tool-calling (yang sebenarnya dibutuhkan agen):

| Kandidat     | Payload besar | Tool-calling | Latensi | Jadi reference juga? |
|--------------|---------------|--------------|---------|----------------------|
| `muse`       | 5/5           | **0/3** ❌   | ~40 s   | **ya** (kini) ⚠️     |
| `muse-spark-1.3` (model asli) | **1/5** ❌ | 0/3 ❌ | ~16 s | –            |
| `anti`       | 5/5           | 3/3          | 3,9 s   | tidak                |
| **`codebudy`** | **6/6**     | **3/3**      | **3,4 s** | **tidak** ✅      |
| `gemini`     | 5/5           | 3/3          | 5,2 s   | tidak                |
| `xkiro`      | 3/3           | 3/3          | 3,5 s   | tidak                |
| `antigravity`| 5/7           | 3/3          | 5,7 s   | tidak                |

Catatan: `anti` adalah *meta-combo* yang isinya termasuk `codebudy`, `xkiro`,
`agnes`, `harbor`, `antigravity`, `gemini`. Kalau `anti` jadi aggregator
**sekaligus** reference, sang "juri" menilai jawabannya sendiri →
**independensi MoA hilang**. Karena itu aggregator selalu dipilih dari combo
yang **bukan** salah satu reference.

`codebudy` dipilih atas permintaan user: stabil (6/6 payload besar),
tool-calling sehat (3/3), dan cepat (3,4 s).

## Kenapa `muse` boleh jadi reference

`muse` punya kelemahan tool-calling (0/3, timeout ~98 s) — **tidak masalah**
untuk reference karena reference tidak pernah memanggil tool. Yang tersisa
hanyalah latensi: saat diuji `muse` menjawab teks 200 dalam ~6 s (bukan ~40 s
seperti pada uji payload besar), jadi masih wajar sebagai penasihat.

## Riwayat aggregator (penting saat debug)

Aggregator pernah berpindah beberapa kali; urutannya:

1. `muse` — gagal: payload besar 1/6, tool-calling 0/3.
2. `anti` — ditolak: dobel peran (aggregator + reference) → independensi hilang.
3. `gemini` — dipakai sebentar.
4. `xkiro` — **tidak tercatat sebagai keputusan**; config berubah ke `xkiro`
   pada 2026-10-11 11:06:11 (di luar sesi yang mendokumentasikan). Backup
   `config.yaml.bak.aggxkiro.20261011T110609` isinya masih `gemini`, jadi
   perubahan itu terjadi setelah backup. Bila ada yang aneh, cek trace MoA
   terbaru untuk aggregator yang **benar-benar** dipakai.
5. **`codebudy` — kondisi sekarang** (permintaan user).

> Pelajaran: `config.yaml` bisa berubah tanpa jejak di repo. Selalu verifikasi
> dengan `python scripts/hermes-verify-moa.py` atau lihat trace MoA terbaru
> (`moa-traces/*.jsonl` → field `aggregator`), jangan percaya ingatan/commit.

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

Verifier MoA membaca peran dari env dan **memeriksa independensi**
(aggregator ≠ reference):

```
MOA_AGG=codebudy   MOA_REFS=anti,muse,agnes   # default sekarang
```

Bukti E2E: `hermes -z "..."` dengan tool-use berhasil — aggregator `codebudy`
memanggil `find`/`ls` sendiri dan bahkan mengoreksi jawaban reference yang
salah. Trace `moa-traces/*.jsonl` mencatat `agg=custom:codebudy`,
`refs=[anti, muse, agnes]`.

## Celah yang masih terbuka

- Semua peran lewat satu router lokal (`localhost:20128`) — satu titik gagal.
  Fallback di atas mengurangi, bukan menghapus, risiko ini.
- Akar masalah socket upstream Muse (`502 UND_ERR_SOCKET: other side closed`)
  belum hilang; hanya tertutupi oleh failover.
- `config.yaml` dapat diubah oleh proses di luar repo (lihat riwayat
  aggregator di atas) — jangan asumsikan isinya tanpa memverifikasi.
