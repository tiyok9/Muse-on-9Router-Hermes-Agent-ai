# Recon SSH — Muse VM (2026-10-02)

Hasil probe read-only di VM Muse. Tidak ada perubahan yang dilakukan saat recon.

| # | Item | Hasil |
|---|------|-------|
| 1 | OS | `Ubuntu 24.04.5 LTS`, `x86_64` |
| 2 | SSH client | `/usr/bin/ssh`, `scp`, `ssh-keygen`, `ssh-agent` — **OpenSSH 9.6p1** |
| 2 | SSH **server** | `sshd` **TIDAK ADA** di `command -v` |
| 3 | sshd proses / listen | **TIDAK ADA proses sshd**, **TIDAK listen di :22** |
| 4 | Hak akses | `uid=0(root)` → **SUDO-OK** (sudah root) |
| 5 | Paket manager | `/usr/bin/apt-get`, `/usr/bin/apt` |
| 6 | Egress TCP :22 | **TCP22-OK** ← kunci: reverse tunnel bisa |
| 7 | Egress TCP :443 | **TCP443-OK** |
| 8 | `~/.ssh/` | `id_ed25519` (600) + `id_ed25519.pub` — keypair **sudah ada**; tanpa `config`; tanpa `known_hosts` |
| 9 | Service ssh/tunnel | tidak ada |
| 10 | Bridge | `curl 127.0.0.1:8765/health` → `{"ok": true}` (masih hidup) |

## Kesimpulan

**Yang bisa:** VM ini bisa **dial keluar** ke port 22 (TCP22-OK) dan punya root + apt.
Artinya **SSH reverse tunnel (`ssh -R`) dari VM ke relay Anda = bisa.**

**Yang tidak bisa:** VM ini **tidak menjalankan sshd**, jadi tidak bisa di-`ssh` masuk secara langsung
dari luar — sama seperti tembok yang membatalkan rencana Tailscale (VM tidak bisa menerima koneksi masuk).

## Bentuk solusi

```
[ laptop Anda ] --ssh--> [ relay milik Anda ] <--dial keluar ssh-- [ Muse VM ]
                              ^ mempublikasikan 127.0.0.1:8765
```

VM mendial keluar ke relay dengan `ssh -R`. Koneksi keluar itu yang jadi jalur masuk —
tanpa membuka port apa pun di VM.

## Dua tingkat akses

| Tingkat | Butuh | Hasil |
|---------|-------|-------|
| **Bridge (HTTP)** | tidak ada tambahan | `ssh -R 8765:127.0.0.1:8765 relay` → bridge Muse terjangkau dari luar |
| **Shell SSH penuh** | **`apt install openssh-server`** (mengubah sistem) | `ssh -R 2222:127.0.0.1:22 relay` → `ssh -p 2222 user@relay` = shell di VM |

Tingkat kedua butuh **izin eksplisit** karena memasang paket baru di VM Muse.
