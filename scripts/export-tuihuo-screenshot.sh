#!/usr/bin/env bash
set -euo pipefail

# 用法：
#   ./scripts/export-tuihuo-screenshot.sh "阿飞 18612759109 北京市昌平区沙河镇万橡悦府一期17号楼4单元301"
#
# 原理：
#   脚本会临时启动本地网页服务，把整段地址传给 tuihuo.html 的 shot=1 模式，
#   再用 Chrome headless（无界面浏览器）截出 1179x2556 的完整 PNG。

ADDRESS_TEXT="${*:-}"
if [[ -z "$ADDRESS_TEXT" ]]; then
  echo "错误：请把姓名、手机号、地址作为参数传进来。" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$CHROME_BIN" ]]; then
  echo "错误：没有找到 Google Chrome，无法自动截图。" >&2
  exit 1
fi

PORT="$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"

TMP_PROFILE="$(mktemp -d)"
SERVER_LOG="$(mktemp)"
CHROME_LOG="$(mktemp)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_PROFILE" "$SERVER_LOG" "$CHROME_LOG"
}
trap cleanup EXIT

(cd "$ROOT_DIR" && python3 -m http.server "$PORT" --bind 127.0.0.1 >"$SERVER_LOG" 2>&1) &
SERVER_PID="$!"

for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:${PORT}/tuihuo.html" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

ENCODED_TEXT="$(python3 - "$ADDRESS_TEXT" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1]))
PY
)"

FILE_STEM="$(python3 - "$ADDRESS_TEXT" <<'PY'
import re
import sys

text = sys.argv[1].strip()
all_labels = r"收件人|收货人|联系人|姓名|名字|商家名称|商家名|手机号码|手机号|联系电话|电话|手机|所在地区|地区|省市区|详细地址|地址详情|地址信息|商家地址|退货地址|寄回地址|收件地址|收货地址|地址"
address_start_re = re.compile(r"(?:北京市|天津市|上海市|重庆市|[^\s]{2,8}(?:省|自治区|特别行政区)|[^\s]{2,8}市|[^\s]{2,8}县)")
compact_address_name_re = re.compile(r"^(.+(?:菜鸟驿站|驿站|小区|社区|花园|家园|嘉园|公寓|大厦|中心|广场|一期|二期|三期|四期|五期|[0-9一二三四五六七八九十]+号楼|[0-9一二三四五六七八九十]+栋|[0-9一二三四五六七八九十]+幢|[0-9一二三四五六七八九十]+室|湾|苑|府|园|城))([\u4e00-\u9fa5]{2,4})$")

def extract_label(labels):
  label_group = "|".join(labels)
  pattern = rf"(?:^|[\n\s])(?:{label_group})\s*[:：]\s*([\s\S]*?)(?=(?:[\n\s]+(?:{all_labels})\s*[:：])|$)"
  match = re.search(pattern, text)
  return re.sub(r"\s+", "", match.group(1).strip()) if match else ""

phone_match = re.search(r"1[3-9]\d{9}", text)
phone = phone_match.group(0) if phone_match else ""
name_part = extract_label(["收件人", "收货人", "联系人", "姓名", "名字", "商家名称", "商家名"])
if not name_part:
  name_part = text[:phone_match.start()].strip() if phone_match else "退货"
  before_phone = re.sub(r"[，,]", " ", name_part)
  before_phone = re.sub(r"\s+", " ", before_phone).strip()
  parts = [part for part in before_phone.split(" ") if part]
  # 文件名也兼容“地址 姓名 手机号”格式，避免截图名变成整段地址。
  if len(parts) >= 2 and address_start_re.search(before_phone) and address_start_re.search(before_phone).start() == 0:
    name_part = parts[-1]
  elif address_start_re.search(before_phone) and address_start_re.search(before_phone).start() == 0:
    # 兼容“地址姓名手机号”连写文件名：只在地址尾词明确时拆出最后 2-4 个中文姓名。
    compact_match = compact_address_name_re.match(before_phone)
    if compact_match:
      name_part = compact_match.group(2)
name_part = re.sub(r"\s+", "", name_part)
name_part = re.sub(r"(?:商家|卖家|退货|寄回|寄件|收货|收件|地址|联系)?信息$", "", name_part)
name_part = re.sub(r"^(?:联系人|收件人|收货人|姓名|名字|商家名称|商家名)[:：]?", "", name_part)
name_part = re.sub(r"(?:手机号码|手机号|联系电话|电话|手机|所在地区|地区|省市区|详细地址|地址详情|地址信息)[:：]?$", "", name_part)
safe_name = re.sub(r"[/:*?\"<>|\\]", "_", name_part or "退货")
print(f"{safe_name}-{phone}" if phone else safe_name)
PY
)"

OUT_PATH="${HOME}/Downloads/寄回商品详情-${FILE_STEM}.png"
URL="http://127.0.0.1:${PORT}/tuihuo.html?shot=1&text=${ENCODED_TEXT}"

python3 - "$CHROME_BIN" "$OUT_PATH" "$URL" "$TMP_PROFILE" "$CHROME_LOG" <<'PY'
import os
import subprocess
import sys
import time

chrome_bin, out_path, url, profile_dir, chrome_log = sys.argv[1:6]
cmd = [
  chrome_bin,
  "--headless=new",
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-background-networking",
  "--disable-gpu",
  "--hide-scrollbars",
  "--force-device-scale-factor=1",
  "--window-size=1179,2556",
  f"--user-data-dir={profile_dir}",
  f"--screenshot={out_path}",
  url,
]

with open(chrome_log, "w") as log:
  proc = subprocess.Popen(cmd, stdout=log, stderr=log)

deadline = time.time() + 25
last_size = -1
stable_since = None

while time.time() < deadline:
  if os.path.exists(out_path):
    size = os.path.getsize(out_path)
    if size > 10000 and size == last_size:
      stable_since = stable_since or time.time()
      if time.time() - stable_since >= 0.8:
        break
    else:
      last_size = size
      stable_since = None

  if proc.poll() is not None:
    break

  time.sleep(0.2)

if proc.poll() is None:
  proc.terminate()
  try:
    proc.wait(timeout=3)
  except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait(timeout=3)

if not os.path.exists(out_path):
  raise SystemExit("错误：Chrome 没有生成截图文件。")
PY

python3 - "$OUT_PATH" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, "rb") as f:
  header = f.read(24)
if header[:8] != b"\x89PNG\r\n\x1a\n":
  raise SystemExit("错误：导出的不是 PNG 文件。")
width, height = struct.unpack(">II", header[16:24])
if (width, height) != (1179, 2556):
  raise SystemExit(f"错误：截图尺寸不对，当前是 {width}x{height}。")
PY

echo "$OUT_PATH"
