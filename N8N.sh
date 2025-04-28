#!/bin/bash

# === CONFIGURATION ===
# Thư mục cài đặt n8n và lưu dữ liệu
N8N_DIR="/opt/n8n"
N8N_DATA_DIR="${N8N_DIR}/data"

# Timezone cho n8n (Ví dụ: Asia/Ho_Chi_Minh)
N8N_TIMEZONE="Asia/Ho_Chi_Minh"

# Token Cloudflare Tunnel
# LƯU Ý: Đây là thông tin nhạy cảm!
CF_TOKEN="eyJhIjoiZWNhMjg3MTJiZjY0N2I2ZmYyNDBkZjU4MjZlNWNkOTYiLCJ0IjoiMTczYTU3YjctMjBlOS00ZDI0LThiN2QtN2JjMGY0YzE1NTgzIiwicyI6Ik1qazROekkzWmpjdE5UWXlNaTAwTldWaExUaGhaV010WXpaaVpEQXhNakF4TnpkaSJ9"

# === SCRIPT START ===

# Dừng script nếu có lỗi
set -e

# Kiểm tra quyền root
if [ "$(id -u)" -ne 0 ]; then
  echo ">>> Script này cần được chạy với quyền root (sudo)."
  exit 1
fi

echo ">>> Bắt đầu quá trình cài đặt n8n và Cloudflare Tunnel..."

# 1. Cập nhật hệ thống và cài đặt các gói cần thiết
echo ">>> 1/5: Cập nhật hệ thống và cài đặt các gói cần thiết..."
apt update
apt upgrade -y
apt install -y curl wget gnupg lsb-release ca-certificates apt-transport-https

# 2. Cài đặt Docker và Docker Compose
echo ">>> 2/5: Cài đặt Docker và Docker Compose..."
if ! command -v docker &> /dev/null; then
    echo ">>> Docker chưa được cài đặt. Tiến hành cài đặt..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    # Thêm người dùng hiện tại (nếu đang chạy sudo từ user thường) vào group docker
    # Nếu bạn chạy script trực tiếp bằng root thì không cần thiết lắm
    if [ -n "$SUDO_USER" ]; then
        usermod -aG docker "$SUDO_USER"
        echo ">>> Đã thêm người dùng '$SUDO_USER' vào nhóm 'docker'. Bạn cần đăng xuất và đăng nhập lại để thay đổi có hiệu lực khi chạy lệnh docker không cần sudo."
    fi
    echo ">>> Docker đã được cài đặt."
else
    echo ">>> Docker đã được cài đặt."
fi

# Kiểm tra Docker Compose (thường được cài cùng Docker qua script trên)
if ! docker compose version &> /dev/null; then
    echo ">>> Docker Compose (v2 plugin) không tìm thấy. Thử cài đặt lại..."
    apt install docker-compose-plugin -y
    if ! docker compose version &> /dev/null; then
       echo ">>> LỖI: Không thể cài đặt Docker Compose plugin. Vui lòng kiểm tra thủ công."
       exit 1
    fi
fi
echo ">>> Docker Compose đã sẵn sàng."


# 3. Thiết lập và chạy n8n với Docker Compose
echo ">>> 3/5: Thiết lập và chạy n8n..."

echo ">>> Tạo thư mục cho n8n: ${N8N_DIR}"
mkdir -p "${N8N_DATA_DIR}"
# Không cần chmod/chown nếu chạy bằng docker mặc định, trừ khi có lỗi permission

echo ">>> Tạo file docker-compose.yml cho n8n tại ${N8N_DIR}/docker-compose.yml"
cat << EOF > "${N8N_DIR}/docker-compose.yml"
version: '3.7'

services:
  n8n:
    image: n8nio/n8n
    container_name: n8n
    restart: always
    ports:
      - "127.0.0.1:5678:5678" # Chỉ expose cho localhost, cloudflared sẽ kết nối vào đây
    environment:
      - N8N_HOST=\${N8N_HOST} # Sẽ dùng trong tương lai nếu cần custom domain trực tiếp
      - N8N_PORT=5678
      - N8N_PROTOCOL=http # Cloudflare sẽ xử lý HTTPS
      - NODE_ENV=production
      - WEBHOOK_URL=\${WEBHOOK_URL} # Sẽ được Cloudflare Tunnel xử lý
      - GENERIC_TIMEZONE=${N8N_TIMEZONE}
    volumes:
      - ./data:/home/node/.n8n # Sử dụng đường dẫn tương đối tới thư mục data
    # Thêm user nếu bạn muốn chạy container với user không phải root (an toàn hơn)
    # user: "1000:1000" # Đảm bảo thư mục data có quyền ghi cho UID/GID này

networks:
  default:
    name: n8n_network
EOF

echo ">>> Khởi chạy n8n container..."
cd "${N8N_DIR}"
# Sử dụng docker compose thay vì docker-compose (chuẩn mới)
docker compose up -d

echo ">>> Đợi n8n khởi động (khoảng 30 giây)..."
sleep 30

# Kiểm tra nhanh xem n8n có chạy không
if curl --fail http://127.0.0.1:5678 > /dev/null 2>&1; then
    echo ">>> n8n đang chạy tại http://127.0.0.1:5678"
else
    echo ">>> CẢNH BÁO: Không thể kết nối tới n8n tại http://127.0.0.1:5678. Kiểm tra logs bằng 'docker logs n8n'"
    # Không dừng script ở đây, có thể n8n cần thêm thời gian
fi


# 4. Cài đặt Cloudflared
echo ">>> 4/5: Cài đặt Cloudflared..."

# Xác định kiến trúc (thường là arm64 cho Orange Pi 3B)
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" != "arm64" ]; then
   echo ">>> CẢNH BÁO: Kiến trúc là $ARCH. Script này được tối ưu cho arm64. Có thể cần điều chỉnh link download cloudflared."
   # Bạn có thể thêm điều kiện khác ở đây nếu cần hỗ trợ armhf chẳng hạn
fi

CF_DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
CF_DEB_FILE="/tmp/cloudflared-linux-${ARCH}.deb"

echo ">>> Tải Cloudflared (${ARCH}) từ ${CF_DOWNLOAD_URL}..."
wget -O "${CF_DEB_FILE}" "${CF_DOWNLOAD_URL}"

echo ">>> Cài đặt Cloudflared từ file .deb..."
dpkg -i "${CF_DEB_FILE}" || apt --fix-broken install -y # Cài đặt và sửa lỗi dependency nếu có
dpkg -i "${CF_DEB_FILE}" # Thử cài lại sau khi sửa lỗi dependency

echo ">>> Dọn dẹp file cài đặt..."
rm "${CF_DEB_FILE}"

echo ">>> Cloudflared đã được cài đặt."


# 5. Đăng ký và khởi chạy Cloudflared service
echo ">>> 5/5: Đăng ký và khởi chạy Cloudflared service..."

echo ">>> Sử dụng token để đăng ký service cloudflared..."
# Lệnh này sẽ tạo file config và cert trong /etc/cloudflared/ (hoặc ~/.cloudflared nếu chạy không root)
# và tạo systemd service unit.
cloudflared service install "${CF_TOKEN}"

echo ">>> Kích hoạt và khởi động service cloudflared..."
systemctl enable --now cloudflared

echo ">>> Đợi cloudflared kết nối (khoảng 10 giây)..."
sleep 10

echo ">>> Kiểm tra trạng thái service cloudflared:"
systemctl status cloudflared --no-pager

# === HOÀN TẤT ===
echo ""
echo "=================================================="
echo ">>> QUÁ TRÌNH CÀI ĐẶT HOÀN TẤT <<<"
echo "=================================================="
echo ""
echo "* n8n đang chạy dưới dạng Docker container."
echo "  - Kiểm tra logs: docker logs n8n"
echo "  - Dừng n8n: cd ${N8N_DIR} && docker compose down"
echo "  - Khởi động lại n8n: cd ${N8N_DIR} && docker compose up -d"
echo "  - Truy cập nội bộ: http://<IP_ORANGE_PI>:5678 (nếu bạn thay đổi port mapping)"
echo ""
echo "* Cloudflared đang chạy như một service."
echo "  - Kiểm tra logs: journalctl -u cloudflared -f"
echo "  - Trạng thái service: systemctl status cloudflared"
echo "  - Khởi động lại service: systemctl restart cloudflared"
echo ""
echo "* QUAN TRỌNG: Đảm bảo bạn đã cấu hình Tunnel trong Cloudflare Zero Trust Dashboard:"
echo "  - Tunnel Name: n8n-Doanh (hoặc tương ứng với ID 173a57b7-20e9-4d24-8b7d-7bc0f4c15583)"
echo "  - Public Hostname: n8n.doanh.id.vn"
echo "  - Service: **http://localhost:5678** (Để truy cập n8n qua web)"
echo "    (Nếu bạn thực sự muốn SSH, hãy đổi thành ssh://localhost:22 và đảm bảo SSH server đang chạy)"
echo ""
echo ">>> Sau khi cấu hình đúng trên Cloudflare, bạn sẽ có thể truy cập n8n qua https://n8n.doanh.id.vn"
echo ""
if [ -n "$SUDO_USER" ]; then
    echo ">>> NHẮC NHỞ: Đăng xuất và đăng nhập lại để có thể chạy lệnh 'docker' mà không cần 'sudo'."
fi
echo "=================================================="
