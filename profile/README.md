<p align="center">
  <img src="keel-mark-512.png" alt="Keel Linux" width="160">
</p>

<h1 align="center">Keel Linux</h1>

<p align="center">
  Declarative, layered, IPv6-first system-container appliances.<br>
  Compatible with TurnKey Linux appliances.
</p>

## What Keel is

Keel Linux is a fork of TurnKey Linux 19 (Debian 13) that makes the LXC
appliance behave like a cloud instance:

- **Declared in one file, applied idempotently.** An instance spec describes
  hostname, IPv6 networking, domain and certificate policy, services, users
  and secrets by reference. The interactive console writes the same file.
- **Built from layers, addressed by content, signed.** Core, stack and app are
  separate layers with a plain-text manifest, so an appliance update
  downloads what changed, and anyone can verify what they run.
- **Reachable end to end over IPv6.** Every appliance gets its own routable
  address, certificate and identity. IPv4 is optional and never assumed.
- **Maintainable across years and major versions.** Platform upgrades and
  application schema upgrades are kept apart, and the second is orchestrated
  with a return point, the upstream tool, validation and rollback.

The container model is the system container: full init, journal, cron, SSH,
filesystem-level backup. No other container runtime is involved.

## Repositories

Forks of the TurnKey Linux tooling and appliances, with full history and the
upstream kept as a remote: `tkldev`, `fab`, `common`, `buildtasks`,
`inithooks`, `confconsole`, `webmin`, `turnkey-chroot`, `tklbam`,
`tklbam-profiles`, `cdroots`, and the appliance recipes (`core`, `lamp`,
`lapp`, `nginx-php-fastcgi`, `wordpress`, `moodle`, `odoo`, `redis`,
`ejabberd`). New code lives in `keel`, the library and command line that the
console and the build tools call.

## Standards

- Every change ships with tests: at least 90 percent coverage for anything in
  these repositories, 95 percent for code the project writes.
- IPv6 in every example, default and command.
- English in commits, code and documentation.
- History is never rewritten.

## Status

Early. The build host builds unmodified 19.0 reproducibly from these forks,
the first bug fixes are on branches, and the first pieces of the library
(instance spec, layer verification) exist with full test coverage. Nothing is
published for end users yet.
