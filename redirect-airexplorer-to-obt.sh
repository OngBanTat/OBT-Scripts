#!/usr/bin/env bash
# Redirect www.airexplorer.net -> IP của ongbantat.store trong /etc/hosts
# Hỗ trợ: setup (thêm entry) và remove (gỡ entry)

set -euo pipefail

SOURCE_DOMAIN="ongbantat.store"
TARGET_DOMAIN="www.airexplorer.net"
HOSTS_FILE="/etc/hosts"
MARKER="# obt-redirect"

# ── Helpers ────────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 [setup|remove|trust-cert]"
  echo ""
  echo "  setup       Trỏ $TARGET_DOMAIN -> IP của $SOURCE_DOMAIN"
  echo "  remove      Gỡ entry $TARGET_DOMAIN khỏi $HOSTS_FILE"
  echo "  trust-cert  Tin tưởng certificate từ $TARGET_DOMAIN (sau khi setup)"
  exit 1
}

resolve_ip() {
  local ip
  ip=$(dig +short "$SOURCE_DOMAIN" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  if [[ -z "$ip" ]]; then
    echo "ERROR: Không thể resolve IP của $SOURCE_DOMAIN" >&2
    exit 1
  fi
  echo "$ip"
}

entry_exists() {
  grep -q "$TARGET_DOMAIN" "$HOSTS_FILE" 2>/dev/null
}

remove_entry() {
  sudo sed -i '' "/$TARGET_DOMAIN/d" "$HOSTS_FILE"
}

# ── Actions ────────────────────────────────────────────────────────────────────

do_setup() {
  local ip
  ip=$(resolve_ip)
  echo "IP của $SOURCE_DOMAIN: $ip"

  if entry_exists; then
    # Kiểm tra IP có khớp không
    local current_ip
    current_ip=$(grep "$TARGET_DOMAIN" "$HOSTS_FILE" | awk '{print $1}' | head -1)
    if [[ "$current_ip" == "$ip" ]]; then
      echo "Entry đã tồn tại và đúng IP ($ip). Không cần cập nhật."
      exit 0
    fi
    echo "Cập nhật IP cũ ($current_ip) -> mới ($ip)..."
    remove_entry
  fi

  echo "$ip $TARGET_DOMAIN $MARKER" | sudo tee -a "$HOSTS_FILE" > /dev/null
  echo "Done. Đã thêm: $ip $TARGET_DOMAIN"
  echo "Kiểm tra: ping -c1 $TARGET_DOMAIN"
}

do_remove() {
  if entry_exists; then
    remove_entry
    echo "Done. Đã gỡ entry $TARGET_DOMAIN khỏi $HOSTS_FILE"
  else
    echo "Không tìm thấy entry $TARGET_DOMAIN trong $HOSTS_FILE"
  fi
}

# ── Trust cert ────────────────────────────────────────────────────────────────

do_trust_cert() {
  local domain="$TARGET_DOMAIN"
  local cert_file
  cert_file=$(mktemp /tmp/obt-cert-XXXXXX.pem)

  echo "Tải certificate từ $domain..."
  if ! openssl s_client -connect "$domain:443" -servername "$domain" \
       </dev/null 2>/dev/null | \
       openssl x509 -outform PEM > "$cert_file" 2>/dev/null; then
    echo "ERROR: Không thể lấy certificate từ $domain" >&2
    rm -f "$cert_file"
    exit 1
  fi

  local subject
  subject=$(openssl x509 -noout -subject -in "$cert_file" 2>/dev/null | sed 's/subject=//')
  echo "Certificate subject: $subject"

  local os
  os=$(uname -s)

  if [[ "$os" == "Darwin" ]]; then
    echo "Thêm certificate vào macOS Keychain (System)..."
    sudo security add-trusted-cert \
      -d \
      -r trustRoot \
      -k /Library/Keychains/System.keychain \
      "$cert_file"
    echo "Done. Certificate đã được tin tưởng trên macOS."
    echo "Lưu ý: Có thể cần restart browser để có hiệu lực."

  elif [[ "$os" == "Linux" ]]; then
    local ca_dir
    if [[ -d /usr/local/share/ca-certificates ]]; then
      # Debian/Ubuntu
      ca_dir="/usr/local/share/ca-certificates"
      local dest="$ca_dir/obt-redirect-${domain//\./-}.crt"
      sudo cp "$cert_file" "$dest"
      sudo update-ca-certificates
    elif [[ -d /etc/pki/ca-trust/source/anchors ]]; then
      # RHEL/CentOS/Fedora
      ca_dir="/etc/pki/ca-trust/source/anchors"
      local dest="$ca_dir/obt-redirect-${domain//\./-}.pem"
      sudo cp "$cert_file" "$dest"
      sudo update-ca-trust extract
    else
      echo "ERROR: Không nhận diện được hệ thống CA trên Linux." >&2
      rm -f "$cert_file"
      exit 1
    fi
    echo "Done. Certificate đã được tin tưởng trên Linux."
    echo "Lưu ý: Có thể cần restart browser để có hiệu lực."
  else
    echo "ERROR: Hệ điều hành $os chưa được hỗ trợ." >&2
    rm -f "$cert_file"
    exit 1
  fi

  rm -f "$cert_file"
}

# ── Interactive menu nếu không có args ────────────────────────────────────────

choose_action() {
  echo "=== OBT Redirect Tool (macOS/Linux) ==="
  echo "Domain nguồn : $SOURCE_DOMAIN"
  echo "Domain đích  : $TARGET_DOMAIN"
  echo ""
  echo "Chọn hành động:"
  echo "  1) Setup      - Thêm redirect vào $HOSTS_FILE"
  echo "  2) Remove     - Gỡ redirect khỏi $HOSTS_FILE"
  echo "  3) Trust Cert - Tin tưởng certificate từ $TARGET_DOMAIN"
  echo "  4) Thoát"
  echo ""
  read -rp "Lựa chọn (1/2/3/4): " choice
  case "$choice" in
    1) do_setup ;;
    2) do_remove ;;
    3) do_trust_cert ;;
    4) exit 0 ;;
    *) echo "Lựa chọn không hợp lệ."; exit 1 ;;
  esac
}

# ── Entry point ────────────────────────────────────────────────────────────────

case "${1:-}" in
  setup)      do_setup ;;
  remove)     do_remove ;;
  trust-cert) do_trust_cert ;;
  "")         choose_action ;;
  *)          usage ;;
esac
