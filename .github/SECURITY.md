# Security policy

## Supported versions

Security fixes are applied to the current **beta** and **stable** release channels published on [GitHub Releases](https://github.com/Scdouglas1999/Skotiq/releases). Older versions may not receive patches.

| Channel | Typical support |
|--------|------------------|
| Latest release | Yes |
| Previous stable | Best effort |
| Pre-release / dev builds | No guarantee |

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report sensitive issues privately by emailing the maintainer (use the contact address on your GitHub profile or the address listed on the project website when available). Include:

- A description of the issue and impact
- Steps to reproduce
- Affected version and platform
- Any proof-of-concept you are comfortable sharing

You should receive an acknowledgment within a reasonable timeframe. We will coordinate disclosure and a fix before public details are published when appropriate.

## Scope notes

Skotiq is designed for **local observatory LANs**. Remote control and the web dashboard assume a trusted network; exposing the headless API or dashboard directly to the public internet without additional hardening is out of scope for default configurations.

When reporting remote-control issues, specify whether the deployment used token authentication, TLS termination, and firewall rules from [Headless secure setup](../docs/headless-secure-setup.md).
