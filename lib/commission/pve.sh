# shellcheck shell=bash
# The Proxmox side of keel-commission: everything it does on the PVE host
# and inside the machine under test goes through these functions.
#
# KC_PVE is the command that reaches the PVE host, split into words, for
# example "ssh -o BatchMode=yes -p 7082 root@pve.example". Every remote
# command is one string, so it reaches the host as an operator types it.

# pve CMD...: run a command on the PVE host.
pve() {
    # shellcheck disable=SC2086
    $KC_PVE "$@"
}

# pve_retry COMMAND: COMMAND on the PVE host, up to three times. Machines
# made at the same time on one storage wait for its lock, and pct or qm
# gives up with "can't lock file" (BR2, 2026-11-06, three at once on
# local-zfs).
pve_retry() {
    local try
    for try in 1 2 3; do
        pve "$1" && return 0
        [ "$try" = 3 ] || sleep "$KC_POLL"
    done
    return 1
}

# guest_sh: run the script on stdin inside the machine, as root. A secret
# that a check needs goes in the script, so it never is on a command line.
guest_sh() {
    if [ "${KC_KIND:-lxc}" = vm ]; then
        vm_guest_sh
        return
    fi
    # --norc: bash sources ~/.bashrc when it sees SSH_CLIENT, which pct exec
    # passes on from the ssh session, and the .bashrc of root starts
    # confconsole once (BR2, 2026-11-05): a check must not spend that.
    # pct exec keeps the PATH of the PVE host's shell, without /usr/local,
    # where an appliance keeps tools such as wp-cli: a login has it
    pve "pct exec $KC_VMID -- env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash --norc -s"
}

# template_sha VOLID: the sha256 of the template file the pass boots.
template_sha() {
    pve "sha256sum \"\$(pvesm path '$1')\"" | cut -d' ' -f1
}

# ct_create VOLID: make the machine as an operator makes it: an unprivileged
# container from the template, nesting on, nothing preseeded, and the root
# password the Proxmox web interface asks for, KC_LOGIN_SECRET. That one is
# no secret of the contract: the first boot must replace it with the root
# secret, and the root proof checks the root secret. KC_CT_OPTS adds the
# site's storage and network options.
ct_create() {
    pve_retry "pct create $KC_VMID '$1' --hostname kc$KC_VMID --unprivileged 1 --features nesting=1 --password '$KC_LOGIN_SECRET' $KC_CT_OPTS"
}

ct_start() {
    pve "pct start $KC_VMID"
}

# ct_destroy: remove the machine, unless --keep was given. A machine that
# is not there is not an error.
ct_destroy() {
    [ "$KC_KEEP" = 1 ] && return 0
    pve "pct stop $KC_VMID >/dev/null 2>&1; pct destroy $KC_VMID --purge 1 >/dev/null 2>&1; true"
}

# ct_write_instance DIR: put DIR/etc/keel/instance.yaml and the secret
# files of DIR/etc/keel/secrets into the stopped machine before its first
# boot, owned by its root and readable by root only, as instance.example.yaml
# of an appliance says to. /etc/keel of the image keeps its own owner and
# mode (--no-overwrite-dir).
#
# The path pct mount names must end in /VMID/rootfs, or nothing is
# written: on 2026-11-05 a path that did not parse came out empty, and the
# description went to /etc/keel of the PVE host itself.
ct_write_instance() {
    tar -C "$1" -cf - etc/keel/instance.yaml etc/keel/secrets \
        | pve "set -e; d=\$(pct mount $KC_VMID | sed -n \"s/^[^']*'\\([^']*\\)'.*/\\1/p\"); case \"\$d\" in /*/$KC_VMID/rootfs) ;; *) pct unmount $KC_VMID; echo \"pct mount named '\$d', not a rootfs of $KC_VMID\" >&2; exit 1 ;; esac; test -d \"\$d/etc\"; o=\$(stat -c %u:%g \"\$d/etc\"); [ -d \"\$d/etc/keel\" ] || { mkdir \"\$d/etc/keel\"; chown \"\$o\" \"\$d/etc/keel\"; }; tar -x -C \"\$d\" --no-same-owner --no-overwrite-dir -f -; chown -R \"\$o\" \"\$d/etc/keel/instance.yaml\" \"\$d/etc/keel/secrets\"; chmod 0600 \"\$d/etc/keel/instance.yaml\"; chmod 0700 \"\$d/etc/keel/secrets\"; pct unmount $KC_VMID"
}

# ct_wait_firstboot: wait until the first boot has run to its end, which
# is when inithooks writes RUN_FIRSTBOOT=false. Fails after KC_BOOT_TIMEOUT
# seconds.
ct_wait_firstboot() {
    local waited=0
    while [ "$waited" -lt "$KC_BOOT_TIMEOUT" ]; do
        if printf 'grep -qx RUN_FIRSTBOOT=false /etc/default/inithooks\n' \
            | guest_sh 2>/dev/null; then
            return 0
        fi
        sleep "$KC_POLL"
        waited=$((waited + KC_POLL))
    done
    return 1
}
