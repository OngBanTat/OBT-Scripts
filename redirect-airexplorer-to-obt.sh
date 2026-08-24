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
  echo "Usage: $0 [setup|remove]"
  echo ""
  echo "  setup   Trỏ $TARGET_DOMAIN -> IP của $SOURCE_DOMAIN"
  echo "  remove  Gỡ entry $TARGET_DOMAIN khỏi $HOSTS_FILE"
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

# ── Interactive menu nếu không có args ────────────────────────────────────────

choose_action() {
  echo "=== OBT Redirect Tool (macOS/Linux) ==="
  echo "Domain nguồn : $SOURCE_DOMAIN"
  echo "Domain đích  : $TARGET_DOMAIN"
  echo ""
  echo "Chọn hành động:"
  echo "  1) Setup   - Thêm redirect vào $HOSTS_FILE"
  echo "  2) Remove  - Gỡ redirect khỏi $HOSTS_FILE"
  echo "  3) Thoát"
  echo ""
  read -rp "Lựa chọn (1/2/3): " choice
  case "$choice" in
    1) do_setup ;;
    2) do_remove ;;
    3) exit 0 ;;
    *) echo "Lựa chọn không hợp lệ."; exit 1 ;;
  esac
}

# ── Entry point ────────────────────────────────────────────────────────────────

case "${1:-}" in
  setup)  do_setup ;;
  remove) do_remove ;;
  "")     choose_action ;;
  *)      usage ;;
esac
