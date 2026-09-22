# SECURITY AUDIT — hermes-homelab
# Date: 2026-09-20
# Verdict: Multiple gaps found and fixed

## FINDING 1: IPv6 bypass (CRITICAL)
- iptables only blocks IPv4. Docker can enable IPv6.
- If host has IPv6, container could reach LAN via IPv6 addresses.
- FIX: Add ip6tables rules to block all IPv6 except loopback.

## FINDING 2: Missing no-new-privileges (HIGH)
- Without `--security-opt=no-new-privileges`, setuid binaries inside
  the container can escalate privileges.
- FIX: Add `security_opt: [no-new-privileges:true]` to compose.

## FINDING 3: DNS rebinding attack (MEDIUM)
- An attacker-controlled DNS name (evil.com) could return 192.168.1.5
- Our iptables block destination 192.168.0.0/16, so this IS blocked.
- BUT we should verify this works end-to-end.

## FINDING 4: No ulimits (LOW)
- No fork bomb / resource exhaustion protection.
- FIX: Add ulimits (nproc, nofile) to compose.

## FINDING 5: Docker socket access (NOT PRESENT — OK)
- We do NOT mount /var/run/docker.sock — confirmed safe.

## FINDING 6: hermes user can read /etc/shadow (LOW)
- read_only prevents writes, but the user can still read system files.
- Not critical since there's nothing sensitive in the container's /etc,
  but defense-in-depth says remove setuid/setgid binaries.

## FINDING 7: IPv6 RA / ICMP (LOW)
- Router advertisements could auto-configure IPv6.
- FIX: Disable IPv6 sysctl inside container.

## PERSISTENCE AUDIT
- Docker named volumes persist across `docker compose down && up`
- Named volumes persist across `docker compose build --no-cache && up`
- Named volumes are ONLY lost on `docker compose down -v` (explicit delete)
- hermes update (pip) requires image rebuild → volume survives
- VERDICT: Persistence is sound.
