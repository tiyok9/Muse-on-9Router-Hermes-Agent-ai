# Prompt: Muse Bridge over Tailscale (Windows, satu mesin atau satu tailnet)

Copy-paste **seluruh blok** di bawah ini sebagai satu prompt ke agent yang punya
akses shell ke mesin target. Lampirkan `bridge.py` (v5.1) dan `bridge-worker.py`.

Versi ini menggantikan tunnel publik (cloudflared) dengan **Tailscale**: bridge
mendengarkan di `127.0.0.1` **dan** di IP tailnet, worker tetap menarik job
secara outbound, jadi tidak ada port inbound yang dibuka ke internet.

---

```
Setup "Muse Bridge + 9Router + Hermes" via Tailscale di mesin Windows ini,
end-to-end dalam satu sesi. Jangan pernah menampilkan nilai key/token di chat.

KONTEKS
- bridge.py v5.1 sudah mendukung Tailscale: saat serve, ia selalu listen di
  127.0.0.1 DAN di `tailscale ip -4` (lihat listen_addrs()). Tidak perlu
  cloudflared / port-forward.
- bridge-worker.py adalah worker pull-based (GET /muse/pending -> POST
  /muse/answer). Semua koneksinya outbound.

LANGKAH

1. Prasyarat + identitas tailnet
   - verifikasi `python --version` >= 3.8 dan `tailscale version`.
   - jalankan `tailscale ip -4` dan `tailscale status --json`, catat IPv4 dan
     MagicDNS name (Self.DNSName tanpa titik akhir).
   - kalau `tailscale ip -4` kosong: berhenti dan minta saya login
     (`tailscale up`) — jangan lanjut dengan asumsi alamat.

2. Deploy bridge
   - taruh bridge.py di folder ini, buat folder queue/.
   - generate key: `python bridge.py keygen --role user --label 9router` dan
     `python bridge.py keygen --role worker --label muse-worker`.
   - kunci keys.json (chmod 600 di Linux/macOS; ACL khusus user di Windows),
     lalu verifikasi dengan `python bridge.py keylist` (hanya prefix).
   - jalankan `python bridge.py serve` sebagai background service, konfirmasi
     baris "listening on 127.0.0.1:8765" DAN "listening on <tailscale-ip>:8765".

3. Uji jangkauan Tailscale (bukan cuma localhost)
   - `curl http://127.0.0.1:8765/health`          -> {"ok": true}
   - `curl http://<tailscale-ip>:8765/health`     -> {"ok": true}
   - `curl http://<magicdns>:8765/health`         -> {"ok": true}
   - kalau IP tailnet gagal tapi localhost jalan: laporkan sebagai kegagalan
     langkah ini, jangan diam-diam lanjut.

4. Worker
   - set BRIDGE_URL ke `http://<tailscale-ip>:8765` (bukan 127.0.0.1) supaya
     jalur yang dipakai sama dengan jalur tailnet.
   - UPSTREAM: tanya saya dulu — `hermes`, endpoint OpenAI-compatible lain,
     atau `none` (echo) untuk uji konektivitas.
   - JANGAN set UPSTREAM ke bridge itu sendiri; worker menolak start kalau
     host:port-nya sama dengan BRIDGE_URL (guard anti-loop).
   - jalankan `python bridge-worker.py --once` sekali, lalu `--loop` sebagai
     service (WATCH_DIR=<queue>/pending untuk bangun instan).

5. Uji end-to-end + catat angkanya
   (a) POST /v1/chat/completions (model "muse") lewat 127.0.0.1  -> waktu
   (b) POST yang sama lewat <tailscale-ip>                        -> waktu
   (c) `hermes -z "apakah kamu terhubung via 9Router ke provider Muse?"`
   (d) cek `GET /muse/pending` mengembalikan count 0 setelah (a)-(c)
   Laporkan durasi tiap uji.

6. 9Router + Hermes
   - 9Router: provider node openai-compatible -> `http://<tailscale-ip>:8765/v1`
     (atau 127.0.0.1 kalau 9Router di mesin yang sama), API key = user key,
     lalu bikin combo model publik bernama "muse".
   - Hermes: custom provider -> base_url `http://<tailscale-ip>:8765/v1`,
     api_key lewat env (bukan literal di config), model default "muse".
   - verifikasi `GET /v1/models` mengembalikan id "muse".

7. Klien dari mesin lain di tailnet
   - dari mesin kedua (kalau ada): `curl http://<tailscale-ip>:8765/health`.
   - ingatkan saya: klien tailnet lain butuh user key; worker key jangan
     dibagikan.
   - kalau saya ingin expose lewat Funnel: jelaskan bahwa itu membuka bridge
     ke internet publik dan minta konfirmasi eksplisit sebelum menjalankan
     `tailscale funnel`.

8. Backup + laporan
   - backup keys.json ke file terpisah permission 600.
   - laporkan ringkas: lokasi service/config/backup, IPv4 + MagicDNS, hasil
     tiap uji beserta angkanya, dan status worker (upstream apa).
   - tutup dengan menanyakan bot mau ke WhatsApp, Telegram, atau Discord,
     lalu setup Hermes gateway sesuai pilihan (minta token + user ID saya,
     batasi akses hanya ke user ID itu).
```

---

## Yang perlu disiapkan sebelum menjalankan prompt

| Bahan | Dari siapa | Keterangan |
|-------|-----------|------------|
| `bridge.py` (v5.1) | repo ini | Lampirkan bersama prompt |
| `bridge-worker.py` | repo ini | Worker pull-based (Tailscale-friendly) |
| Tailscale terpasang + login | Kamu | `tailscale up` di mesin bridge; `tailscale ip -4` harus keluar |
| Keputusan upstream | Kamu | `hermes`, endpoint lain, atau `none` |
| Token bot | Kamu | Diberikan saat agent bertanya di langkah 8 |

## Catatan Tailscale

- **Bind otomatis.** `bridge.py` v5.1 sudah membaca `tailscale ip -4` dan listen
  di semua alamat itu plus `127.0.0.1`. Kalau `tailscale` tidak ada di PATH,
  bridge tetap jalan tapi hanya di localhost — script `setup-bridge.ps1` akan
  memperingatkan ini.
- **Tanpa port inbound.** Worker menarik job secara outbound, jadi tidak ada
  listener yang perlu dibuka. Tailscale ACL cukup mengizinkan port 8765.
- **MagicDNS vs IP.** IP `100.x.y.z` stabil per-node; MagicDNS lebih enak dibaca
  tapi butuh MagicDNS aktif di tailnet. Prompt memverifikasi keduanya.
- **Funnel ≠ tailnet.** Tailscale biasa hanya menjangkau perangkat di tailnet
  Anda. Kalau bridge perlu diakses dari internet publik, itu `tailscale funnel`
  dan membuka permukaan serangan — prompt sengaja meminta konfirmasi eksplisit.
- **`tailscale ip -4` dievaluasi saat start.** Kalau node dapat IP baru (jarang),
  restart bridge supaya listener ikut alamat baru.
