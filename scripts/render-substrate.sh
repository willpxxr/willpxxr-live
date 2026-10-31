#!/usr/bin/env bash
# Render upstream Agent Substrate ("ate") v0.6.0 install manifests into
# apps/substrate for the de/hetzner fleet -- WEP-0016 Phase 1.
#
# Everything fleet-specific is pinned HERE, so an upstream bump is a
# single UPSTREAM_REF edit, a substrate-images workflow dispatch, pasting
# the new digests into the map below, and a rerun of this script:
#
#   - image digests (built by .github/workflows/substrate-images.yaml)
#   - the namespace retarget (upstream pins ate-system; ours is substrate)
#   - the objectstore-plugin S3 env (Hetzner Object Storage, nbg1)
#
# Output contract (consumed by apps/substrate/app.yaml manifests globs):
#   rendered/core/     -- the first-push set
#   rendered/dataplane/ -- atenet router + egress, deliberately EXCLUDED
#                          from app.yaml until the socket-LB worker-path
#                          probes pass (the 2026-07/08 precedent class).
# The podcert controller keeps its upstream-owned namespace
# (podcertificate-controller-system) -- retargeting it would break its
# own $(POD_NAMESPACE) wiring.
set -euo pipefail

UPSTREAM_REF="v0.6.0"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/gitops/clusters/de/hetzner/cluster/apps/substrate"
OUT_CORE="$APP_DIR/rendered/core"
OUT_DP="$APP_DIR/rendered/dataplane"

# Digests from CI run 40390956929 (byte-identical across rebuilds).
# Written as from|to lines and parsed by a read-loop: macOS still ships
# bash 3.2, which has no associative arrays.
IMAGE_MAP='
ko://go.ate.dev/substrate/cmd/ateapi|ghcr.io/willpxxr/ateapi@sha256:7b6759a57c20e45f1d2cc05ff439e61e68c48f9b22cc94fd9fd359b1ca61b41f
ko://go.ate.dev/substrate/cmd/atecontroller|ghcr.io/willpxxr/atecontroller@sha256:c454250f3c14f2ddcf0334c9b7bb2ce7f157b8be0fc8df25ff09a495f9b88a61
ko://go.ate.dev/substrate/cmd/atelet|ghcr.io/willpxxr/atelet@sha256:29e6185385a69cd434c70dfeaac696bf26a5c1c7c754c58efdd9a0d9c74e4fde
ko://go.ate.dev/substrate/cmd/atenet|ghcr.io/willpxxr/atenet@sha256:db74a0f05c664468de16d06016a03e20732bfe7ad05739ad6bb719b3fdcbaf7c
ko://go.ate.dev/substrate/cmd/ate-idp-server|ghcr.io/willpxxr/ate-idp-server@sha256:655392ce4642af764e2ffe866e6bbd8c02b22244fd951deca301092ddd142db4
ko://go.ate.dev/substrate/cmd/objectstore-plugin|ghcr.io/willpxxr/objectstore-plugin@sha256:2628df2db37880a8717addc6e86450fa4af7bfbb2fa4468c1b9e7e7389a5bcc3
ko://go.ate.dev/substrate/cmd/podcertcontroller|ghcr.io/willpxxr/podcertcontroller@sha256:81285dae3dd5edd84442e846208b2459571d07acf689d6ab553bc58a0c19a5f2
'
ENVOY_DATAPLANE_IMAGE="ghcr.io/willpxxr/envoy-dataplane@sha256:add7d0c62748b7e4e5c772a9dab740d54bebcf078546982a356ed62178baff50"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "Cloning agent-substrate/substrate@${UPSTREAM_REF}..."
git clone --depth 1 --branch "$UPSTREAM_REF" \
  https://github.com/agent-substrate/substrate.git "$WORK/src" >/dev/null
SRC="$WORK/src/manifests/ate-install"

CORE_FILES=(
  ate-api-server.yaml ate-idp-server.yaml ate-controller.yaml atelet.yaml
  ate-otel-config.yaml ate-system-networkpolicies.yaml
  pod-certificate-controller.yaml sandboxconfig-gvisor.yaml
)
CRD_FILES=(
  generated/ate.dev_sandboxconfigs.yaml
  generated/ate.dev_workerpools.yaml
  generated/ate.dev_csidriverconfigs.yaml
  generated/role.yaml
)
DP_FILES=(atenet-router.yaml atenet-router-monitoring.yaml atenet-egress.yaml)

rm -rf "$OUT_CORE" "$OUT_DP"
mkdir -p "$OUT_CORE" "$OUT_DP"

S3_ENV_REPLACEMENT=$(cat <<'EOF'
        # Rendered by scripts/render-substrate.sh (WEP-0016 Phase 1):
        # snapshot backend = Hetzner Object Storage (nbg1, same network
        # zone as the cluster), static keys from the ESO-materialized
        # substrate-s3 Secret -- held control-plane-side only, never
        # inside actors.
        - name: ATE_STORAGE_BACKEND
          value: "s3"
        - name: AWS_REGION
          value: "nbg1"
        - name: AWS_ENDPOINT_URL
          value: "https://nbg1.your-objectstorage.com"
        - name: AWS_S3_USE_PATH_STYLE
          value: "true"
        - name: AWS_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef:
              name: substrate-s3
              key: access-key-id
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: substrate-s3
              key: secret-access-key
EOF
)
export S3_ENV_REPLACEMENT

render_one() { # $1 = upstream-relative path, $2 = destination file
  local src="$SRC/$1" dst="$2" key val
  cp "$src" "$dst"
  while IFS='|' read -r img_from img_to; do
    case "$img_from" in ''|'#'*) continue ;; esac
    # Replacement text goes through %ENV: perl's s/// replacement parses
    # @ sigils (the @sha256: in a digest ref would interpolate as an array
    # and silently vanish with bash-style interpolation).
    IMG_FROM="$img_from" IMG_TO="$img_to" \
      perl -pi -e 's|\Q$ENV{IMG_FROM}\E|$ENV{IMG_TO}|g' "$dst"
  done <<EOF
${IMAGE_MAP}
EOF
  ENVOY_TO="$ENVOY_DATAPLANE_IMAGE" \
    perl -pi -e 's|\$\{ENVOY_DATAPLANE_IMAGE\}|$ENV{ENVOY_TO}|g' "$dst"
  # Namespace retarget: metadata.namespace fields only (line-exact so
  # ate-system.svc DNS literals or other namespaces are left untouched).
  perl -pi -e 's|^(\s*)namespace: ate-system$|$1namespace: substrate|' "$dst"
  # Tracing is dormant on this fleet (otel stack disabled fleet-wide, see
  # AGENTS Observability): reroute the OTEL exporter to loopback so the
  # dormant path fails fast and quietly instead of resolving/connecting
  # to the GKE-managed collector that does not exist here.
  perl -pi -e 's|^(\s*OTEL_EXPORTER_OTLP_ENDPOINT:) http://opentelemetry-collector\.gke-managed-otel\.svc\.cluster\.local:4317$|$1 http://127.0.0.1:4317|' "$dst"
  # Objectstore sidecar S3 env (ate-api-server + atelet only).
  python3 - "$dst" <<'PYEOF'
import os, sys
path = sys.argv[1]
anchor = '        - name: ATE_STORAGE_BACKEND\n          value: "gcs"\n'
raw = open(path).read()
if 'ATE_STORAGE_BACKEND' in raw:
    if raw.count(anchor) != 1:
        sys.exit(f"{path}: expected exactly 1 sidecar anchor, found {raw.count(anchor)}")
    open(path, "w").write(raw.replace(anchor, os.environ["S3_ENV_REPLACEMENT"] + "\n"))
    print(f"  {os.path.basename(path)}: sidecar S3 env patched")
PYEOF
}

echo "Rendering core:"
for f in "${CORE_FILES[@]}"; do
  render_one "$f" "$OUT_CORE/$(basename "$f")"
done
for f in "${CRD_FILES[@]}"; do
  echo "  $(basename "$f")"
  render_one "$f" "$OUT_CORE/$(basename "$f")"
done

echo "Rendering dataplane (excluded from app.yaml until socket-LB probes pass):"
for f in "${DP_FILES[@]}"; do
  render_one "$f" "$OUT_DP/$(basename "$f")"
done

echo "Verifying: no unreplaced refs survive..."
if grep -rnE 'ko://|\$\{ENVOY_DATAPLANE_IMAGE\}|namespace: ate-system' "$OUT_CORE" "$OUT_DP"; then
  echo "ERROR: unreplaced upstream references remain" >&2
  exit 1
fi
echo "OK: $(ls "$OUT_CORE" | wc -l | tr -d ' ') core files, $(ls "$OUT_DP" | wc -l | tr -d ' ') dataplane files rendered into apps/substrate/rendered/."
