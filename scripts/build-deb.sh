#!/usr/bin/env bash
# Build a self-contained Vault Debian package for the architecture requested by
# VAULT_DEB_ARCH. This deliberately preserves the files and maintainer scripts
# from the upstream Vault package so upgrades retain the vault user, systemd
# service, and /etc/vault.d configuration model.
set -euo pipefail

: "${VAULT_DEB_VERSION:?set VAULT_DEB_VERSION, e.g. 2.0.3+devopshouse.1}"
: "${VAULT_DEB_ARCH:=arm64}"
: "${VAULT_DEB_OUT_DIR:=dist}"

case "${VAULT_DEB_VERSION}" in
  *+*)
    vault_base_version="${VAULT_DEB_VERSION%%+*}"
    vault_version_metadata="${VAULT_DEB_VERSION#*+}"
    ;;
  *)
    vault_base_version="${VAULT_DEB_VERSION}"
    vault_version_metadata=""
    ;;
esac

case "${vault_base_version}" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *)
    echo "VAULT_DEB_VERSION must start with a semantic version: ${VAULT_DEB_VERSION}" >&2
    exit 2
    ;;
esac

case "${VAULT_DEB_ARCH}" in
  arm64) vault_goarch=arm64 ;;
  amd64) vault_goarch=amd64 ;;
  *)
    echo "Unsupported Debian architecture: ${VAULT_DEB_ARCH}" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
mkdir -p "${VAULT_DEB_OUT_DIR}"

revision="$(git rev-parse HEAD)"
build_date="$(git show --no-show-signature -s --format=%cd --date=format:%Y-%m-%dT%H:%M:%SZ HEAD)"
ldflags="-X github.com/hashicorp/vault/version.GitCommit=${revision} -X github.com/hashicorp/vault/version.BuildDate=${build_date} -X github.com/hashicorp/vault/version.Version=${vault_base_version}"
if [[ -n "${vault_version_metadata}" ]]; then
  ldflags+=" -X github.com/hashicorp/vault/version.VersionMetadata=${vault_version_metadata}"
fi

echo "Building Vault ${VAULT_DEB_VERSION} for linux/${vault_goarch}"
CGO_ENABLED=0 GOOS=linux GOARCH="${vault_goarch}" \
  go build -trimpath -buildvcs=false -tags ui -ldflags "${ldflags}" -o "${VAULT_DEB_OUT_DIR}/vault" .

stage_dir="$(mktemp -d)"
trap 'rm -rf "${stage_dir}"' EXIT

install -D -m 0755 "${VAULT_DEB_OUT_DIR}/vault" "${stage_dir}/usr/bin/vault"
install -D -m 0644 .release/linux/package/usr/lib/systemd/system/vault.service "${stage_dir}/usr/lib/systemd/system/vault.service"
install -D -m 0644 .release/linux/package/etc/vault.d/vault.hcl "${stage_dir}/etc/vault.d/vault.hcl"
install -D -m 0644 .release/linux/package/etc/vault.d/vault.env "${stage_dir}/etc/vault.d/vault.env"
install -D -m 0644 LICENSE "${stage_dir}/usr/share/doc/vault/LICENSE.txt"
install -D -m 0755 .release/linux/preinst "${stage_dir}/DEBIAN/preinst"
install -D -m 0755 .release/linux/postinst "${stage_dir}/DEBIAN/postinst"
install -D -m 0755 .release/linux/postrm "${stage_dir}/DEBIAN/postrm"

cat > "${stage_dir}/DEBIAN/control" <<EOF
Package: vault
Version: ${VAULT_DEB_VERSION}
Section: utils
Priority: optional
Architecture: ${VAULT_DEB_ARCH}
Depends: openssl
Maintainer: devopshouse
Homepage: https://github.com/devopshouse/vault
Description: Vault is a tool for secrets management, encryption as a service, and privileged access management.
EOF
cat > "${stage_dir}/DEBIAN/conffiles" <<'EOF'
/etc/vault.d/vault.hcl
/etc/vault.d/vault.env
EOF

deb_path="${VAULT_DEB_OUT_DIR}/vault_${VAULT_DEB_VERSION}_${VAULT_DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "${stage_dir}" "${deb_path}"
dpkg-deb --info "${deb_path}"
