#!/usr/bin/env bash
# Redirect www.airexplorer.net và airexplorer.net -> IP của ongbantat.store
# Hỗ trợ: setup (thêm entry), remove (gỡ entry), trust-cert, untrust-cert

set -euo pipefail

SOURCE_DOMAIN="ongbantat.store"
TARGET_DOMAINS=("www.airexplorer.net")
# Thêm bare domain (không www.) cho hosts.
ALL_HOSTS_DOMAINS=("${TARGET_DOMAINS[@]}")
for d in "${TARGET_DOMAINS[@]}"; do
  bare="${d#www.}"
  [[ "$bare" != "$d" ]] && ALL_HOSTS_DOMAINS+=("$bare")
done
HOSTS_FILE="/etc/hosts"
MARKER="# obt-redirect"

# ── Helpers ────────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 [setup|remove|trust-cert|untrust-cert]"
  echo ""
  echo "  setup        Trỏ ${TARGET_DOMAINS[*]} -> IP của $SOURCE_DOMAIN"
  echo "  remove       Gỡ entry ${TARGET_DOMAINS[*]} khỏi $HOSTS_FILE"
  echo "  trust-cert   Tin tưởng certificate từ ${TARGET_DOMAINS[*]} (sau khi setup)"
  echo "  untrust-cert Gỡ certificate OBT khỏi hệ thống CA"
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
  local domain="$1"
  # Space đứng trước domain tránh match substring (www.airexplorer.net vs airexplorer.net).
  grep -q " ${domain} ${MARKER}" "$HOSTS_FILE" 2>/dev/null
}

remove_entry() {
  local domain="$1"
  sudo sed -i '' "/ ${domain} ${MARKER}/d" "$HOSTS_FILE"
}

# ── Actions ────────────────────────────────────────────────────────────────────

do_setup() {
  local ip
  ip=$(resolve_ip)
  echo "IP của $SOURCE_DOMAIN: $ip"

  local changed=0
  for domain in "${ALL_HOSTS_DOMAINS[@]}"; do
    if entry_exists "$domain"; then
      local current_ip
      current_ip=$(grep " ${domain} ${MARKER}" "$HOSTS_FILE" | awk '{print $1}' | head -1)
      if [[ "$current_ip" != "$ip" ]]; then
        echo "  [UPDATE] $domain - IP cũ=$current_ip -> mới=$ip"
      fi
      remove_entry "$domain"
    else
      echo "  [ADD] $domain -> $ip"
    fi
    echo "$ip $domain $MARKER" | sudo tee -a "$HOSTS_FILE" > /dev/null
    changed=1
  done

  if [[ "$changed" -eq 1 ]]; then
    echo "Done. Đã cập nhật hosts. Kiểm tra: ping -c1 ${TARGET_DOMAINS[0]}"
  else
    echo "Không có thay đổi."
  fi
}

do_remove() {
  local found=0
  for domain in "${ALL_HOSTS_DOMAINS[@]}"; do
    if entry_exists "$domain"; then
      remove_entry "$domain"
      echo "  [REMOVED] $domain"
      found=1
    else
      echo "  [NOT FOUND] $domain - không có entry"
    fi
  done

  if [[ "$found" -eq 1 ]]; then
    echo "Done. Đã gỡ redirect khỏi $HOSTS_FILE."
  else
    echo "Không tìm thấy entry nào trong $HOSTS_FILE."
  fi
}

# ── Trust cert ────────────────────────────────────────────────────────────────

do_trust_cert() {
  # Xóa cert cũ trước, rồi lấy cert mới nhất từ TLS.
  do_untrust_cert
  echo ""

  local os
  os=$(uname -s)
  local ok=0

  for domain in "${TARGET_DOMAINS[@]}"; do
    echo "Tải certificate chain từ $domain..."
    local cert_file
    cert_file=$(mktemp /tmp/obt-cert-XXXXXX.pem)

    # -showcerts lấy toàn bộ chain (leaf + intermediate + root)
    if ! openssl s_client -connect "$domain:443" -servername "$domain" -showcerts \
         </dev/null 2>/dev/null | \
         awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} /-----END CERTIFICATE-----/{f=0}' \
         > "$cert_file" 2>/dev/null; then
      echo "  ERROR: Không thể lấy certificate từ $domain" >&2
      rm -f "$cert_file"
      continue
    fi

    if [[ ! -s "$cert_file" ]]; then
      echo "  ERROR: Không lấy được certificate nào từ $domain" >&2
      rm -f "$cert_file"
      continue
    fi

    local count
    count=$(grep -c "BEGIN CERTIFICATE" "$cert_file")
    echo "  Đã nhận $count certificate(s) trong chain."

    if [[ "$os" == "Darwin" ]]; then
      echo "  Thêm certificate chain vào macOS Keychain (Login) - Always Trust..."
      local split_files
      split_files=$(split_pem "$cert_file")

      # Trust settings plist:信任 mọi purpose (SSL, S/MIME, etc.)
      local trust_plist="/tmp/obt-trust-$$.plist"
      cat > "$trust_plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>keychain</key>
	<string>~/Library/Keychains/login.keychain-db</string>
	<key>trustSettings</key>
	<dict>
		<key>kSecTrustSettingsResult</key>
		<integer>1</integer>
	</dict>
</dict>
</plist>
PLIST

      while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        security add-trusted-cert \
          -r trustRoot \
          -k ~/Library/Keychains/login.keychain-db \
          -i "$trust_plist" \
          "$c"
      done <<< "$split_files"
      rm -f "$trust_plist"
      [[ -n "$split_files" ]] && rm -f $split_files
      echo "  Done. Certificate chain đã được tin tưởng (Always Trust) trên macOS."

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
        echo "  ERROR: Không nhận diện được hệ thống CA trên Linux." >&2
        rm -f "$cert_file"
        continue
      fi
      echo "  Done. Certificate chain đã được tin tưởng trên Linux."
    else
      echo "  ERROR: Hệ điều hành $os chưa được hỗ trợ." >&2
      rm -f "$cert_file"
      continue
    fi

    rm -f "$cert_file"
    ok=1
  done

  if [[ "$ok" -eq 1 ]]; then
    echo "Lưu ý: Có thể cần restart browser để có hiệu lực."
  fi
}

# Tách một bundle PEM thành từng file cert, in đường dẫn mỗi file ra stdout
split_pem() {
  local bundle="$1"
  local i=0 tmp
  # Xóa file tạm cũ từ lần chạy trước
  rm -f /tmp/obt-cert-split-*.pem
  while IFS= read -r line; do
    if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
      i=$((i+1))
      tmp=$(mktemp /tmp/obt-cert-split-XXXXXX.pem)
      echo "$tmp"
      echo "$line" >> "$tmp"
    elif [[ -n "$tmp" ]]; then
      echo "$line" >> "$tmp"
      if [[ "$line" == "-----END CERTIFICATE-----" ]]; then
        tmp=""
      fi
    fi
  done < "$bundle"
}

# ── Untrust cert ──────────────────────────────────────────────────────────────

do_untrust_cert() {
  local os
  os=$(uname -s)
  local any_removed=0

  # Thu thập cả bare domain (bỏ www.) — cert CN có thể chỉ ghi tên gốc.
  local all_domains=()
  for d in "${TARGET_DOMAINS[@]}"; do
    all_domains+=("$d")
    local bare="${d#www.}"
    [[ "$bare" != "$d" ]] && all_domains+=("$bare")
  done

  for domain in "${all_domains[@]}"; do
    local cert_name="obt-redirect-${domain//\./-}"

    if [[ "$os" == "Darwin" ]]; then
      # Gỡ từ cả System keychain (sudo) và Login keychain.
      for kc in "/Library/Keychains/System.keychain" "$HOME/Library/Keychains/login.keychain-db"; do
        local kc_name
        [[ "$kc" == *System* ]] && kc_name="System" || kc_name="Login"
        echo "Gỡ certificate chain của $domain khỏi macOS Keychain ($kc_name)..."

        local hashes
        hashes=$(collect_chain_hashes "$domain" "$kc")
        if [[ -z "$hashes" ]]; then
          echo "  Không tìm thấy cert liên quan đến $domain trong $kc_name Keychain."
          continue
        fi
        local removed=0
        while IFS= read -r h; do
          [[ -z "$h" ]] && continue
          echo "  Gỡ certificate: $h"
          if [[ "$kc" == *System* ]]; then
            sudo security delete-certificate -Z "$h" "$kc" && removed=1
          else
            security delete-certificate -Z "$h" "$kc" && removed=1
          fi
        done <<< "$hashes"
        if [[ "$removed" -eq 1 ]]; then
          echo "  Done. Đã gỡ cert chain của $domain khỏi $kc_name Keychain."
          any_removed=1
        fi
      done

    elif [[ "$os" == "Linux" ]]; then
      local removed=0
      if [[ -d /usr/local/share/ca-certificates ]]; then
        local dest="/usr/local/share/ca-certificates/${cert_name}.crt"
        if [[ -f "$dest" ]]; then
          sudo rm -f "$dest"
          sudo update-ca-certificates --fresh
          removed=1
        fi
      fi
      if [[ -d /etc/pki/ca-trust/source/anchors ]]; then
        local dest="/etc/pki/ca-trust/source/anchors/${cert_name}.pem"
        if [[ -f "$dest" ]]; then
          sudo rm -f "$dest"
          sudo update-ca-trust extract
          removed=1
        fi
      fi

      if [[ "$removed" -eq 1 ]]; then
        echo "  Done. Đã gỡ certificate chain của $domain khỏi Linux CA store."
        any_removed=1
      else
        echo "  Không tìm thấy certificate OBT của $domain đã cài trên Linux."
      fi
    else
      echo "ERROR: Hệ điều hành $os chưa được hỗ trợ." >&2
      exit 1
    fi
  done

  if [[ "$any_removed" -eq 1 ]]; then
    echo "Lưu ý: Có thể cần restart browser để có hiệu lực."
  fi
}

# In ra danh sách "hash<TAB>subject<TAB>issuer" của mọi cert trong keychain
dump_keychain_certs() {
  local keychain="${1:-$HOME/Library/Keychains/login.keychain-db}"
  local pem tmp
  while IFS= read -r line; do
    if [[ "$line" == "SHA-1 hash:"* ]]; then
      [[ -n "$pem" ]] && { rm -f "$pem"; pem=""; }
      h="${line##* }"
      pem=$(mktemp /tmp/obt-kc-XXXXXX.pem)
    elif [[ -n "$pem" ]]; then
      echo "$line" >> "$pem"
      if [[ "$line" == "-----END CERTIFICATE-----" ]]; then
        # subject/issuer dạng RFC2253 (OpenSSL mặc định)
        subj=$(openssl x509 -noout -subject -in "$pem" 2>/dev/null | sed 's/subject= *//')
        iss=$(openssl x509 -noout -issuer -in "$pem" 2>/dev/null | sed 's/issuer= *//')
        # SAN: trích các DNS name (bắt cả wildcard, vd: *.airexplorer.net)
        san=$(openssl x509 -noout -ext subjectAltName -in "$pem" 2>/dev/null \
              | sed '1d' | tr ',' '\n' | grep -i 'DNS:' | sed 's/DNS://; s/ //g' | tr '\n' ' ')
        echo -e "${h}\t${subj}\t${iss}\t${san}"
        rm -f "$pem"
        pem=""
      fi
    fi
  done < <(security find-certificate -a -Z -p "$keychain" 2>/dev/null | grep -v '^$')
}

# Thu thập SHA-1 của toàn bộ chain (leaf -> root) theo domain, in ra stdout (mỗi dòng 1 hash)
collect_chain_hashes() {
  local domain="$1"
  local keychain="${2:-$HOME/Library/Keychains/login.keychain-db}"
  local dump="/tmp/obt-dump-$$.tsv"
  rm -f "$dump"
  dump_keychain_certs "$keychain" > "$dump"

  # Tìm leaf: subject hoặc SAN chứa domain (SAN bắt cả wildcard *.domain)
  local leaf_hashes=()
  while IFS=$'\t' read -r h subj iss san; do
    [[ -z "$h" ]] && continue
    if echo "$subj" | grep -qi "$domain"; then
      leaf_hashes+=("$h")
    elif echo "$san" | grep -qi "$domain"; then
      leaf_hashes+=("$h")
    fi
  done < "$dump"

  # Duyệt chain theo Issuer -> Subject (parent: subject == issuer của cert hiện tại)
  local seen=()
  local result=()
  # bash 3.2 (macOS) + set -u: guard empty array expansion
  local queue=()
  [[ ${#leaf_hashes[@]} -gt 0 ]] && queue=("${leaf_hashes[@]}")
  local i=0
  while [[ $i -lt ${#queue[@]} ]]; do
    local h="${queue[$i]}"; i=$((i+1))
    # đã duyệt?
    local dup=0
    [[ ${#seen[@]} -gt 0 ]] && for s in "${seen[@]}"; do [[ "$s" == "$h" ]] && dup=1 && break; done
    [[ "$dup" -eq 1 ]] && continue
    seen+=("$h")
    result+=("$h")

    local cur_iss
    cur_iss=$(awk -F'\t' -v hh="$h" '$1==hh{print $3}' "$dump")
    while IFS=$'\t' read -r ph psubj piss; do
      if [[ "$psubj" == "$cur_iss" && "$ph" != "$h" ]]; then
        queue+=("$ph")
      fi
    done < "$dump"
  done

  [[ ${#result[@]} -gt 0 ]] && printf '%s\n' "${result[@]}"
  rm -f "$dump"
}

# ── Interactive menu nếu không có args ────────────────────────────────────────

show_lite_menu() {
  clear
  echo "=== OBT Redirect Tool (macOS/Linux) ==="
  echo "Domain nguồn : $SOURCE_DOMAIN"
  echo "Domain đích  : ${TARGET_DOMAINS[*]}"
  echo ""
  echo "Chọn hành động:"
  echo "  1) Setup + Trust   - Thêm redirect và cài certificate"
  echo "  2) Untrust + Remove - Gỡ certificate và redirect"
  echo "  3) Chế độ Full"
  echo "  4) Thoát"
  echo ""
}

show_full_menu() {
  clear
  echo "=== OBT Redirect Tool (macOS/Linux) ==="
  echo "Domain nguồn : $SOURCE_DOMAIN"
  echo "Domain đích  : ${TARGET_DOMAINS[*]}"
  echo ""
  echo "Chọn hành động:"
  echo "  1) Setup        - Thêm redirect vào $HOSTS_FILE"
  echo "  2) Remove       - Gỡ redirect khỏi $HOSTS_FILE"
  echo "  3) Trust Cert   - Tin tưởng certificate từ ${TARGET_DOMAINS[*]}"
  echo "  4) Untrust Cert - Gỡ certificate OBT khỏi hệ thống CA"
  echo "  5) Chế độ Lite"
  echo "  6) Thoát"
  echo ""
}

choose_action() {
  local lite=1
  while true; do
    if [[ "$lite" -eq 1 ]]; then
      show_lite_menu
      read -rp "Lựa chọn (1/2/3/4): " choice
      case "$choice" in
        1) do_setup; do_trust_cert ;;
        2) do_untrust_cert; do_remove ;;
        3) lite=0 ;;
        4) echo "Thoát."; exit 0 ;;
        *) echo "Lựa chọn không hợp lệ." ;;
      esac
    else
      show_full_menu
      read -rp "Lựa chọn (1/2/3/4/5/6): " choice
      case "$choice" in
        1) do_setup ;;
        2) do_remove ;;
        3) do_trust_cert ;;
        4) do_untrust_cert ;;
        5) lite=1 ;;
        6) echo "Thoát."; exit 0 ;;
        *) echo "Lựa chọn không hợp lệ." ;;
      esac
    fi
    echo ""
    read -rp "Nhấn phím bất kỳ để tiếp tục..." -n 1
    echo ""
  done
}

# ── Entry point ────────────────────────────────────────────────────────────────

case "${1:-}" in
  setup)        do_setup ;;
  remove)       do_remove ;;
  trust-cert)   do_trust_cert ;;
  untrust-cert) do_untrust_cert ;;
  "")           choose_action ;;
  *)            usage ;;
esac
