# hermes-homelab egress proxy — the single, allowlisted exit point for the
# sandboxed agent. Python stdlib only; ~20MB RAM.
FROM python:3.12-slim

RUN useradd -m -s /usr/sbin/nologin egress \
    && mkdir -p /etc/egress && chown -R egress:egress /etc/egress

COPY proxy.py /app/proxy.py
COPY allowlist.default /etc/egress/allowlist.default

ENV PYTHONUNBUFFERED=1 \
    EGRESS_ALLOWLIST=/etc/egress/allowlist \
    EGRESS_ALLOWLIST_DEFAULT=/etc/egress/allowlist.default \
    EGRESS_PORT=8888

USER egress
EXPOSE 8888
CMD ["python3", "/app/proxy.py"]
