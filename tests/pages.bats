#!/usr/bin/env bats
# pages.py (decision 0077): the page of an application, from a checkout of
# its repository and the records of a passing commissioning run, with no
# invite and no secret on it.

# The README fixture is reStructuredText, with backquotes, in single quotes.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

PAGES="$BATS_TEST_DIRNAME/../lib/commission/pages.py"
SHA_T=1111111111111111111111111111111111111111111111111111111111111111
SHA_I=2222222222222222222222222222222222222222222222222222222222222222
SHA_W=3333333333333333333333333333333333333333333333333333333333333333
TPL=debian-13-keel-demo_19.0-7_amd64.tar.zst
ISO=debian-13-keel-demo_19.0-7_amd64.iso
CORE=debian-13-keel-core_19.0-13_amd64.tar.zst

setup() {
    TMP="$(mktemp -d)"
    REPO="$TMP/keel-demo"
    RUN="$TMP/run"
    OUT="$TMP/out"
    mkdir -p "$REPO/conf.d" "$REPO/packages/keel-demo"
    printf 'keel-demo-19.0 (7) keel; urgency=low\n\n  * first\n' > "$REPO/changelog"
    printf 'DEMO_VERSION=3.2\n' > "$REPO/conf.d/main"
    printf 'Keel Demo\n=========\n\n`Demo`_ 3.2 behind ``nginx``, built on lnpp::\n\n    bt-layer demo\n\n.. _Demo: https://example.invalid\n' > "$REPO/README.rst"
    printf 'modes: [simple, cloud_simple, cloud_advanced]\nprocesses:\n  - name: nginx\n    listen: [{port: 443, protocol: tcp, expose: public}]\n' \
        > "$REPO/packages/keel-demo/manifest.yaml"
    cat > "$TMP/apps.yaml" <<'EOF'
apps:
  demo: {repo: keel-demo, name: Keel Demo, version: Demo 3.2, file: conf.d/main, match: DEMO_VERSION=3.2}
EOF
    printf '%s  %s\n' "$SHA_T" "$TPL" "$SHA_I" "$ISO" "$SHA_W" "$CORE" > "$TMP/images"
    single "$RUN/simple/br1/lxc-interactive" template "local:vztmpl/$TPL" "$SHA_T"
    single "$RUN/simple/br1/vm-iso" iso "local:iso/$ISO" "$SHA_I"
    single "$RUN/simple/br2/lxc-interactive" template "local:vztmpl/$TPL" "$SHA_T"
    cloud "$RUN/cs/cloud_simple" primary replica
    cloud "$RUN/ca/cloud_advanced" primary replica witness
}

teardown() {
    rm -rf "$TMP"
}

# single DIR KEY IMAGE SHA256: a passing pass of one machine, with a text
# frame, a picture and a web picture
single() {
    mkdir -p "$1/screens"
    local site="${1%/*}"
    printf 'pass\t%s\nsite\t%s\n%s\t%s\nsha256\t%s\ncontract\tabc\ndate\t2026-11-06T00:00:00Z\nresult\tpass\n' \
        "${1##*/}" "${site##*/}" "$2" "$3" "$4" > "$1/meta"
    printf 'pass\tkeel-init.asked.root_password\tRoot Password\npass\tservice.nginx\tactive\npass\turl.https://127.0.0.1/\t200\n' \
        > "$1/record.tsv"
    printf 'x Root Password qqqqqq x\n*****************\n' > "$1/screens/01-root_password.txt"
    printf 'PNG' > "$1/screens/02-mode.png"
    printf 'PNG' > "$1/screens/web-01-site.png"
    printf '01\troot_password\tscreens/01-root_password.txt\t(the root secret)\n02\tmode\tscreens/02-mode.png\t<ret>\n01\tweb-site\tscreens/web-01-site.png\topen /\n' \
        > "$1/screens.tsv"
}

# cloud DIR NODE...: a passing pass of several nodes; the first one shows
# the invite screen, the others the join screen. A witness runs the Core
# template, which is not the image of the page (own no).
cloud() {
    local dir="$1" vmid=100 node site image sha own
    shift
    mkdir -p "$dir"
    printf 'pass\t%s\nsite\tbr1\ncontract\tdef\ndate\t2026-11-06T01:00:00Z\nsha256\t%s\nresult\tpass\n' "${dir##*/}" "$SHA_T" > "$dir/meta"
    printf 'pass\tcross.mesh-peer\t2 of 2 nodes (all)\n' > "$dir/record.tsv"
    for node in "$@"; do
        vmid=$((vmid - 1))
        mkdir -p "$dir/$node/screens"
        site=br2
        [ "$node" != replica ] || site=br1
        image=$TPL sha=$SHA_T own=yes
        [ "$node" != witness ] || image=$CORE sha=$SHA_W own=no
        printf 'node\t%s\nsite\t%s\nkind\tlxc\nrole\t%s\nvmid\t%d\nimage\tlocal:vztmpl/%s\nsha256\t%s\nown\t%s\n' \
            "$node" "$site" "$node" "$vmid" "$image" "$sha" "$own" > "$dir/$node/meta"
        printf 'pass\tkeel-init.asked.mode\tInstallation mode\n' > "$dir/$node/record.tsv"
        printf 'Invite a node\nkeel mesh join - <<< <invite 1>\npublic key: AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/abcde=peers: 1\n' \
            > "$dir/$node/screens/01-invite.txt"
        printf '01\tinvite\tscreens/01-invite.txt\t<ret>\n' > "$dir/$node/screens.tsv"
    done
}

build() {
    python3 -I "$PAGES" build demo "$OUT" --apps "$TMP/apps.yaml" --repo "$REPO" --images "$TMP/images" \
        --mode "simple=$RUN/simple" --mode "cloud_simple=$RUN/cs" --mode "cloud_advanced=$RUN/ca/cloud_advanced" "$@"
}

@test "a page shows the version of the application above the Keel release, and the images" {
    run build
    [ "$status" -eq 0 ]
    grep -q '<span class="eyebrow">Keel Demo</span><h1>Demo 3.2</h1>' "$OUT/index.html"
    grep -q 'Keel release <strong>19.0-7</strong>' "$OUT/index.html"
    grep -q "<code>$TPL</code></p><p class=\"sha\">sha256 <code>$SHA_T</code>" "$OUT/index.html"
    grep -q "<code>$ISO</code></p><p class=\"sha\">sha256 <code>$SHA_I</code>" "$OUT/index.html"
    grep -q '<p class="lead">Demo 3.2 behind nginx, built on lnpp.</p>' "$OUT/index.html"
    grep -q '<td>nginx</td><td>443/tcp</td><td>public</td>' "$OUT/index.html"
    grep -q '^\*\{8\}</pre>' "$OUT/index.html"
    run ! grep -q '\*\{9\}' "$OUT/index.html"
    grep -q '<li>Root Password <span class="tag">password</span></li>' "$OUT/index.html"
}

@test "a guide has one column for each node, in the order of their vmid" {
    run build
    [ "$status" -eq 0 ]
    # the nodes are made with falling vmids: the last one comes first
    grep -q '<tr><th>Step</th><th>Replica, BR1</th><th>Primary, BR2</th></tr>' "$OUT/index.html"
    grep -q '<tr><th>Step</th><th>Witness, BR2</th><th>Replica, BR1</th><th>Primary, BR2</th></tr>' "$OUT/index.html"
    grep -q '<h4>the LXC template, answered on the console (br1)</h4>' "$OUT/index.html"
    grep -q '<h4>the ISO in a virtual machine (br1)</h4>' "$OUT/index.html"
    # the second site is in the result table, not in the guides
    [ "$(grep -o '<h4>the ' "$OUT/index.html" | wc -l)" -eq 2 ]
}

@test "the pictures are copied beside the page and linked relative to it" {
    run build
    [ "$status" -eq 0 ]
    [ -f "$OUT/img/br1-vm-iso/vm-iso/02-mode.png" ]
    [ -f "$OUT/img/br1-lxc-interactive/lxc-interactive/web-01-site.png" ]
    grep -q 'src="img/br1-vm-iso/vm-iso/02-mode.png"' "$OUT/index.html"
    run ! grep -q "src=\"/" "$OUT/index.html"
    run ! grep -q "$TMP" "$OUT/index.html"
}

@test "the mark of a masked invite shows as text, and a WireGuard key is not shown" {
    run build
    [ "$status" -eq 0 ]
    grep -q 'keel mesh join - &lt;&lt;&lt; &lt;invite 1&gt;' "$OUT/index.html"
    run ! grep -q 'AbCdEfGhIjKlMnOpQrSt' "$OUT/index.html"
    grep -q 'public key: &lt;public key&gt;peers' "$OUT/index.html"
}

@test "a check that did not pass stops the page, and nothing is written" {
    printf 'fail\tservice.nginx\tinactive\n' >> "$RUN/simple/br2/lxc-interactive/record.tsv"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"1 check(s) did not pass, the first service.nginx"* ]]
    [ ! -e "$OUT" ]
}

@test "a pass whose result is not pass stops the page" {
    sed -i 's/^result\tpass$/result\tfail/' "$RUN/ca/cloud_advanced/meta"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"the result is 'fail', not pass"* ]]
}

@test "a node with a failed check stops the page" {
    printf 'fail\tcross.etcd\t2 of 3\n' > "$RUN/cs/cloud_simple/replica/record.tsv"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"did not pass, the first cross.etcd"* ]]
}

@test "an invite that the run did not mask stops the page" {
    printf 'keel mesh join - <<< keel2:AbCdEfGhIjKlMnOp0123456789\n' > "$RUN/cs/cloud_simple/replica/screens/01-invite.txt"
    mkdir -p "$OUT"
    printf 'old\n' > "$OUT/old.html"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"replica/screens/01-invite.txt: a run like a token"*"a token keel2:AbC..."* ]]
    # a refused page changes nothing in OUT
    [ ! -e "$OUT/index.html" ]
    [ -f "$OUT/old.html" ]
    [ -z "$(find "$TMP" -maxdepth 1 -name '.pages-*')" ]
}

@test "--invites masks the invites and their pieces as mask.py does, and the page is written" {
    printf 'join xkel2:AbCdEfGhIjKlMnOp0123456789x\n' > "$RUN/cs/cloud_simple/replica/screens/01-invite.txt"
    printf 'keel2:AbCdEfGhIjKlMnOp0123456789\n' > "$TMP/invites"
    run build --invites "$TMP/invites"
    [ "$status" -eq 0 ]
    grep -q 'join xk&lt;invite 1&gt;x' "$OUT/index.html"
    run ! grep -q 'IjKlMnOp' "$OUT/index.html"
}

@test "a piece of a given invite of 12 characters is refused even with no mixed case" {
    printf 'abcdefghijklmnop\n' > "$TMP/invites"
    mkdir -p "$TMP/page"
    printf '<p>xbcdefghijklmx</p>\n' > "$TMP/page/index.html"
    run python3 -I "$PAGES" check "$TMP/page" --invites "$TMP/invites"
    [ "$status" -eq 1 ]
    [[ "$output" == *"a piece of an invite"* ]]
    printf '<p>a page with nothing secret, sha256 %s</p>\n' "$SHA_T" > "$TMP/page/index.html"
    mkdir -p "$TMP/page/.git"
    printf 'keel1:AbCdEfGhIjKl0123\n' > "$TMP/page/.git/x"
    printf 'keel1:AbCdEfGhIjKl0123' > "$TMP/page/a.png"
    run python3 -I "$PAGES" check "$TMP/page" --invites "$TMP/invites"
    [ "$status" -eq 0 ]
}

@test "a check across the nodes that did not pass, or no record, stops the page" {
    printf 'fail\tcross.no-vip\t1 of 2 nodes\n' >> "$RUN/cs/cloud_simple/record.tsv"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"cloud_simple: 1 check(s) did not pass, the first cross.no-vip"* ]]
    rm "$RUN/cs/cloud_simple/record.tsv"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"cloud_simple: no record.tsv"* ]]
}

@test "a picture of an invite or a join screen stops the page" {
    printf 'PNG' > "$RUN/cs/cloud_simple/replica/screens/01-join.png"
    printf '01\tjoin\tscreens/01-join.png\t(invite 1 of the first node)<ret>\n' > "$RUN/cs/cloud_simple/replica/screens.tsv"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"a picture of the join screen can hold an invite"* ]]
    [ ! -e "$OUT" ]
}

@test "a pass that ran another sha256 than the image of the list stops the page" {
    sed -i "s/^sha256\t.*/sha256\t$SHA_I/" "$RUN/simple/br2/lxc-interactive/meta"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"br2/lxc-interactive: ran $TPL with sha256 2222222222222222..., the list names 1111111111111111..."* ]]
    [ ! -e "$OUT" ]
}

@test "a pass that names no sha256, or another file, stops the page" {
    sed -i '/^sha256/d' "$RUN/simple/br1/vm-iso/meta"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"br1/vm-iso: ran $ISO with sha256 none, the list names 2222222222222222..."* ]]
    printf 'sha256\t%s\n' "$SHA_I" >> "$RUN/simple/br1/vm-iso/meta"
    sed -i "s/^sha256\t.*/sha256\t$SHA_T/; s/^template\t.*/template\tlocal:vztmpl\/other.tar.zst/" "$RUN/simple/br2/lxc-interactive/meta"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"br2/lxc-interactive: ran other.tar.zst, not $TPL"* ]]
}

@test "a cloud pass or a node of the application with another sha256 stops the page" {
    sed -i "s/^sha256\t.*/sha256\t$SHA_W/" "$RUN/cs/cloud_simple/meta"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"cloud_simple: ran $TPL with sha256 3333333333333333..."* ]]
    sed -i "s/^sha256\t.*/sha256\t$SHA_T/" "$RUN/cs/cloud_simple/meta"
    sed -i "s/^sha256\t.*/sha256\t$SHA_W/" "$RUN/cs/cloud_simple/primary/meta"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"cloud_simple/primary: ran $TPL with sha256 3333333333333333..."* ]]
}

@test "a node of another application must run an image of the list, and not the one of the page" {
    sed -i "s/^sha256\t.*/sha256\t$SHA_T/" "$RUN/ca/cloud_advanced/witness/meta"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"cloud_advanced/witness: own no, but it ran the image of the page"* ]]
    sed -i "s/^sha256\t.*/sha256\t4444444444444444444444444444444444444444444444444444444444444444/" \
        "$RUN/ca/cloud_advanced/witness/meta"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"cloud_advanced/witness: ran $CORE with sha256 4444444444444444..., which the list does not name"* ]]
}

@test "the image list must name one template of the application, at the release of its changelog" {
    printf '%s  %s\n' "$SHA_I" "$ISO" > "$TMP/images"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"names no template of keel-demo"* ]]
    printf '%s  %s\n' "$SHA_T" "${TPL/19.0-7/19.0-8}" "$SHA_I" "${ISO/19.0-7/19.0-8}" > "$TMP/images"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"names keel-demo 19.0-8, but the changelog of the repository says 19.0-7"* ]]
    printf '%s  %s\n' "$SHA_T" "$TPL" "$SHA_T" "${TPL/19.0-7/19.0-6}" > "$TMP/images"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"names 2 templates of keel-demo"* ]]
    printf 'not a line of sha256sum\n' > "$TMP/images"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"images line 1: not SHA256  FILE"* ]]
}

@test "the install section gives the mirror, the Keel index, the signature and the ISO" {
    run build
    [ "$status" -eq 0 ]
    grep -q "https://mirror.keellinux.org/images/$TPL" "$OUT/index.html"
    grep -q "https://mirror.keellinux.org/images/$ISO" "$OUT/index.html"
    grep -q 'keel-pve download local keel-demo' "$OUT/index.html"
    grep -q 'sqv --keyring keel-images-keyring.asc' "$OUT/index.html"
    grep -q 'sha512sum -c' "$OUT/index.html"
    grep -q 'E71DB9C3CA6AC18075395CC3ED3A709C4F3E2F3C' "$OUT/index.html"
    grep -q "pct create 200 local:vztmpl/$TPL" "$OUT/index.html"
}

@test "the page uses the stylesheet, the header and the footer of the site, and has no em dash" {
    run build
    [ "$status" -eq 0 ]
    grep -q '<link rel="stylesheet" href="https://keellinux.org/style.css">' "$OUT/index.html"
    grep -q '<header class="site-header">' "$OUT/index.html"
    grep -q '<footer class="site-footer">' "$OUT/index.html"
    grep -q 'href="https://keellinux.org/appliances.html"' "$OUT/index.html"
    run ! grep -q -e '&#8212;' -e $'\u2014' "$OUT/index.html"
    run ! grep -q -i 'contract' "$OUT/index.html"
}

@test "--evidence reads br1, br2 and cloud of one commissioning folder" {
    local ev="$TMP/commission-demo"
    mkdir -p "$ev/cloud"
    mv "$RUN/simple/br1" "$RUN/simple/br2" "$ev/"
    mv "$RUN/cs/cloud_simple" "$RUN/ca/cloud_advanced" "$ev/cloud/"
    printf '# guide\n' > "$ev/cloud/guide.md"
    run python3 -I "$PAGES" build demo "$OUT" --apps "$TMP/apps.yaml" --repo "$REPO" --images "$TMP/images" --evidence "$ev"
    [ "$status" -eq 0 ]
    grep -q '<h3 id="cloud_simple">' "$OUT/index.html"
    grep -q '<tr><th>Step</th><th>Witness, BR2</th><th>Replica, BR1</th><th>Primary, BR2</th></tr>' "$OUT/index.html"
    grep -q '<h4>the ISO in a virtual machine (br1)</h4>' "$OUT/index.html"
}

@test "a superseded folder is never read" {
    local ev="$TMP/commission-demo-superseded-19.0-6"
    mkdir -p "$ev"
    mv "$RUN/simple/br1" "$ev/"
    run python3 -I "$PAGES" build demo "$OUT" --apps "$TMP/apps.yaml" --repo "$REPO" --images "$TMP/images" --evidence "$ev"
    [ "$status" -eq 1 ]
    [[ "$output" == *"superseded"*"is never used"* ]]
    run build --mode "simple=$ev"
    [ "$status" -eq 1 ]
    [[ "$output" == *"superseded"*"is never used"* ]]
    run python3 -I "$PAGES" build demo "$OUT" --apps "$TMP/apps.yaml" --repo "$REPO" --images "$TMP/images"
    [ "$status" -eq 1 ]
    [[ "$output" == *"give --evidence or --mode"* ]]
}

@test "a secret in a screen stops the page even when it is above the lines that the page shows" {
    # the run of 24 characters is made from 2 halves, so no scanner of the
    # repository reads a secret in this file
    { printf 'the box echoes %s%s\n' Ab3dEfGh1jKl Mn0pQrStUv9x; seq 1 60; } > "$RUN/simple/br1/lxc-interactive/screens/01-root_password.txt"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"screens/01-root_password.txt: a run like a token, Ab3d..."* ]]
    [ ! -e "$OUT" ]
}

@test "keel-app-page runs pages.py build" {
    run "$BATS_TEST_DIRNAME/../bin/keel-app-page" demo "$OUT" --apps "$TMP/apps.yaml" --repo "$REPO" --images "$TMP/images" \
        --mode "simple=$RUN/simple"
    [ "$status" -eq 0 ]
    [ -f "$OUT/index.html" ]
    run "$BATS_TEST_DIRNAME/../bin/keel-app-page" check "$OUT"
    [ "$status" -eq 0 ]
}

@test "a version that the repository no longer says stops the page" {
    printf 'DEMO_VERSION=3.3\n' > "$REPO/conf.d/main"
    run build
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not say 'DEMO_VERSION=3.2': is 'Demo 3.2' still the version?"* ]]
}

@test "an application that apps.yaml does not name, and a bad --mode, are refused" {
    run python3 -I "$PAGES" build other "$OUT" --apps "$TMP/apps.yaml" --repo "$REPO" --images "$TMP/images" --mode "simple=$RUN/simple"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no application 'other'"* ]]
    run build --mode "cloud=$RUN/cs"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MODE=DIR, MODE one of simple, cloud_simple, cloud_advanced"* ]]
    run build --mode "cloud_simple=$TMP/none"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a folder"* ]]
}

@test "the page replaces what was in OUT and keeps the .git of a pages worktree" {
    mkdir -p "$OUT/.git" "$OUT/old"
    printf 'old\n' > "$OUT/old.html"
    run build
    [ "$status" -eq 0 ]
    [ -d "$OUT/.git" ]
    [ ! -e "$OUT/old.html" ]
    [ ! -e "$OUT/old" ]
}

@test "a mode of the manifest with no pass says so" {
    run python3 -I "$PAGES" build demo "$OUT" --apps "$TMP/apps.yaml" --repo "$REPO" --images "$TMP/images" --mode "simple=$RUN/simple"
    [ "$status" -eq 0 ]
    grep -q '<h3 id="cloud_advanced">Cloud advanced: two data nodes and a witness</h3><p>No passing commissioning run of this mode yet.</p>' \
        "$OUT/index.html"
}

@test "with no manifest the page shows the services and the addresses checked" {
    rm -r "$REPO/packages"
    run python3 -I "$PAGES" build demo "$OUT" --apps "$TMP/apps.yaml" --repo "$REPO" --images "$TMP/images" --mode "simple=$RUN/simple"
    [ "$status" -eq 0 ]
    grep -q '<h3>Services</h3><p>nginx</p>' "$OUT/index.html"
    grep -q '<li><code>https://127.0.0.1/</code></li>' "$OUT/index.html"
    run ! grep -q 'id="cloud_simple"' "$OUT/index.html"
}
