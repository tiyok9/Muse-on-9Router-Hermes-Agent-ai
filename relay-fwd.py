#!/usr/bin/env python3
"""relay-fwd.py — TCP forwarder (bridge WireGuard hub -> Muse 9Router).

Muse VM tidak bisa menerima koneksi masuk, jadi VM mendial KELUAR ke relay
(`ssh -R 127.0.0.1:22028:127.0.0.1:20128`). Skrip ini lalu mem-publish port
loopback itu ke alamat WireGuard hub (10.100.0.1:22028) supaya SEMUA peer
WireGuard bisa mengakses 9Router Muse.

Usage: relay-fwd.py <listen_ip> <listen_port> <target_ip> <target_port>
"""
import socket
import sys
import threading

LISTEN_IP = sys.argv[1]
LISTEN_PORT = int(sys.argv[2])
TARGET_IP = sys.argv[3]
TARGET_PORT = int(sys.argv[4])


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client):
    try:
        upstream = socket.create_connection((TARGET_IP, TARGET_PORT), timeout=10)
    except OSError:
        client.close()
        return
    threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pump, args=(upstream, client), daemon=True).start()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTEN_IP, LISTEN_PORT))
    srv.listen(64)
    print(f"[fwd] {LISTEN_IP}:{LISTEN_PORT} -> {TARGET_IP}:{TARGET_PORT}", flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
