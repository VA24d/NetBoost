# Security policy

## Supported versions

NetBoost `v1.0.0` targets macOS 27 (Golden Gate). Older builds receive no security fixes.

## Reporting a vulnerability

Report security bugs privately through [GitHub Security Advisories](https://github.com/VA24d/NetBoost/security/advisories/new). Public issues expose unpatched systems before a fix ships. Never post live credentials or private keys.

Include the app version, macOS build, and steps to reproduce.

## Privilege boundary

Root tasks run inside `com.netboost.helper` at `/Library/PrivilegedHelperTools/com.netboost.helper`. Before sending requests over `/var/run/netboost/helper.sock`, the app checks the installed binary's SHA-256 digest against its bundled copy.

Socket requests pass two checks before execution:

- `LOCAL_PEERCRED` (`xucred`) confirms the caller UID matches `/Library/Application Support/NetBoost/authorized_uid` or root.
- `HelperAction` validation rejects bad interface names, PF anchor names, and out-of-range MTU values.

Validated actions invoke system binaries directly via Foundation `Process` without `/bin/sh`. NetBoost inspects `/bin/ps` for active `eapolclient` processes and respects Apple's `configd` 802.1X Internet Sharing block.
