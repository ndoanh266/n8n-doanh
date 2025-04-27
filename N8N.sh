#!/bin/bash

# === CONFIGURATION ===
# Thư mục cài đặt n8n và lưu dữ liệu
N8N_DIR="/opt/n8n"
N8N_DATA_DIR="${N8N_DIR}/data"

# Timezone cho n8n (Ví dụ: Asia/Ho_Chi_Minh)
# Bạn có thể tìm timezone của mình tại: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
N8N_TIMEZONE="Asia/Ho_Chi_Minh"

# Token Cloudflare Tunnel
# LƯU Ý: Đây là thông tin nhạy cảm! Giữ an toàn.
CF_TOKEN="eyJhIjoiZWNhMjg3MTJiZjY0N2I2ZmYyNDBkZjU4MjZlNWNkOTYiLCJ0IjoiMTczYTU3YjctMjBlOS00ZDI0LThiN2QtN2JjMGY0YzE1NTgzIiwicyI6Ik1qazROekkzWmpjdE5UWXlNaTAwTldWaExUaGhaV010WXpaaVpEQXhNakF4TnpkaSJ9"

# === SCRIPT START ===

# Dừng script nếu có lỗi
set -e

# Kiểm tra quyền root
if [ "$(id -u)" -ne 0 ]; then
  echo ">>> LỖI: Script này cần được chạy với quyền root (sử dụng 'sudo ./N8N.sh')."
  exit 1
fi

echo ">>> Bắt đầu quá trình cài đặt n8n và Cloudflare Tunnel..."

# 1. Cập nhật hệ thống và cài đặt các gói cần thiết
echo ">>> 1/6: Cập nhật hệ thống và cài đặt các gói cần thiết..."
apt update
# Nâng cấp có thể mất nhiều thời gian, nhưng quan trọng để có các bản vá bảo mật và tương thích
apt upgrade -y
# Cài đặt các gói cần thiết cho Docker, Cloudflared và các tiện ích khác
apt install -y curl wget gnupg lsb-release ca-certificates apt-transport-https software-properties-common

# 2. Cài đặt Docker và Docker Compose
echo ">>> 2/6: Cài đặt Docker và Docker Compose..."
if ! command -v docker &> /dev/null; then
    echo ">>> Docker chưa được cài đặt. Tiến hành cài đặt qua script chính thức..."
    # Tải và chạy script cài đặt Docker
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    echo ">>> Docker đã được cài đặt."
else
    echo ">>> Docker đã được cài đặt."
fi

# Thêm người dùng đã gọi sudo vào group docker (nếu có)
# Điều này cho phép chạy lệnh docker mà không cần sudo sau khi đăng xuất/đăng nhập lại
if [ -n "$SUDO_USER" ] && ! groups "$SUDO_USER" | grep -q '\bdocker\b'; then
    usermod -aG docker "$SUDO_USER"
    echo ">>> Đã thêm người dùng '$SUDO_USER' vào nhóm 'docker'."
    echo ">>> LƯU Ý: Bạn cần đăng xuất và đăng nhập lại để chạy lệnh 'docker' mà không cần 'sudo'."
fi

# Kiểm tra Docker Compose (thường được cài cùng Docker qua script trên)
if ! docker compose version &> /dev/null; then
    echo ">>> Docker Compose (v2 plugin) không tìm thấy. Thử cài đặt lại qua apt..."
    apt install docker-compose-plugin -y
    # Kiểm tra lại sau khi cài đặt
    if ! docker compose version &> /dev/null; then
       echo ">>> LỖI: Không thể cài đặt hoặc xác nhận Docker Compose plugin. Vui lòng kiểm tra thủ công."
       exit 1
    fi
fi
echo ">>> Docker Compose đã sẵn sàng."

# 3. Đảm bảo Docker Service đang chạy
echo ">>> 3/6: Đảm bảo Docker service đang chạy và được kích hoạt..."
# Kích hoạt để tự chạy khi khởi động hệ thống
systemctl enable docker
# Khởi động hoặc khởi động lại service để đảm bảo trạng thái mới nhất
systemctl restart docker

# Đợi một chút để service có thời gian khởi động hoàn toàn
echo ">>> Đợi Docker service khởi động (5 giây)..."
sleep 5

# Kiểm tra xem service có đang chạy không
if ! systemctl is-active --quiet docker; then
    echo ">>> LỖI: Không thể khởi động Docker service."
    echo ">>> Vui lòng kiểm tra logs bằng lệnh: 'sudo journalctl -u docker.service -n 50 --no-pager'"
    exit 1
fi
echo ">>> Docker service đang hoạt động."

# 4. Thiết lập và chạy n8n với Docker Compose
echo ">>> 4/6: Thiết lập và chạy n8n..."

echo ">>> Tạo thư mục cho n8n: ${N8N_DIR}"
mkdir -p "${N8N_DATA_DIR}"
# Đặt quyền sở hữu thư mục dữ liệu cho người dùng node trong container (mặc định UID/GID 1000)
# Điều này quan trọng để tránh lỗi quyền ghi volume
chown 1000:1000 "${N8N_DATA_DIR}"

echo ">>> Tạo file docker-compose.yml cho n8n tại ${N8N_DIR}/docker-compose.yml"
# Ghi nội dung file docker-compose.yml
# Sử dụng EOF để dễ dàng ghi nhiều dòng
cat << EOF > "${N8N_DIR}/docker-compose.yml"
version: '3.7' # Phiên bản này vẫn ổn, dù Docker cảnh báo là cũ

services:
  n8n:
    # Sử dụng image n8n chính thức
    image: n8nio/n8n
    container_name: n8n
    # Luôn khởi động lại container nếu nó bị dừng (trừ khi dừng thủ công)
    restart: always
    ports:
      # Chỉ expose cổng 5678 cho localhost (127.0.0.1)
      # Cloudflared sẽ kết nối vào địa chỉ này
      - "127.0.0.1:5678:5678"
    environment:
      # Biến môi trường cho n8n
      # Không cần đặt N8N_HOST vì Cloudflare sẽ xử lý hostname
      - N8N_PORT=5678
      - N8N_PROTOCOL=http # Cloudflare sẽ xử lý HTTPS termination
      - NODE_ENV=production # Chạy ở chế độ production để tối ưu hiệu năng
      # WEBHOOK_URL sẽ tự động được xử lý khi dùng qua tunnel nếu không đặt
      - GENERIC_TIMEZONE=${N8N_TIMEZONE} # Đặt múi giờ
      # Thêm các biến môi trường khác nếu cần tại đây (ví dụ: database config)
    volumes:
      # Mount thư mục dữ liệu n8n vào container
      # Đường dẫn tương đối './data' sẽ trỏ đến ${N8N_DATA_DIR} vì chúng ta sẽ cd vào ${N8N_DIR}
      - ./data:/home/node/.n8n
    # Chạy container với người dùng không phải root để tăng bảo mật
    # UID/GID 1000 là user 'node' mặc định trong image n8n
    user: "1000:1000"

networks:
  default:
    name: n8n_network
EOF

echo ">>> Khởi chạy n8n container trong nền..."
# Chuyển vào thư mục n8n để docker compose sử dụng đường dẫn tương đối trong file yml
cd "${N8N_DIR}"
# Sử dụng docker compose (plugin v2) để khởi chạy
# '-d' để chạy ở chế độ detached (nền)
docker compose up -d

echo ">>> Đợi n8n khởi động hoàn toàn (khoảng 30-60 giây tùy cấu hình)..."
sleep 45 # Tăng thời gian chờ một chút

# Kiểm tra nhanh xem n8n có phản hồi trên cổng localhost không
echo ">>> Kiểm tra kết nối tới n8n trên localhost..."
if curl --fail --silent --max-time 10 http://127.0.0.1:5678 > /dev/null; then
    echo ">>> SUCCESS: n8n đang chạy và phản hồi tại http://127.0.0.1:5678"
else
    echo ">>> CẢNH BÁO: Không thể kết nối tới n8n tại http://127.0.0.1:5678 sau khi chờ."
    echo ">>> Container có thể vẫn đang khởi động hoặc đã gặp lỗi."
    echo ">>> Kiểm tra logs chi tiết bằng lệnh: 'sudo docker logs n8n'"
    # Script sẽ tiếp tục, nhưng n8n có thể chưa sẵn sàng
fi

# 5. Cài đặt Cloudflared
echo ">>> 5/6: Cài đặt Cloudflared..."

# Kiểm tra xem cloudflared đã cài đặt chưa
if command -v cloudflared &> /dev/null; then
    echo ">>> Cloudflared đã được cài đặt. Bỏ qua bước tải và cài đặt."
    # Đảm bảo service được dừng trước khi cài đặt lại (nếu cần)
    systemctl stop cloudflared || true # Dừng nếu đang chạy, bỏ qua lỗi nếu chưa có service
else
    # Xác định kiến trúc hệ thống (thường là arm64 cho Orange Pi 3B với kernel 6.x)
    ARCH=$(dpkg --print-architecture)
    if [ "$ARCH" != "arm64" ]; then
       echo ">>> CẢNH BÁO: Kiến trúc hệ thống là '$ARCH'. Script này được tối ưu cho 'arm64'."
       echo ">>> Đang tiếp tục, nhưng nếu gặp lỗi, bạn có thể cần tìm gói cloudflared phù hợp cho '$ARCH'."
    fi

    # Tạo URL download dựa trên kiến trúc
    CF_DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
    CF_DEB_FILE="/tmp/cloudflared-linux-${ARCH}.deb"

    echo ">>> Tải Cloudflared (${ARCH}) từ ${CF_DOWNLOAD_URL}..."
    # Tải file .deb về thư mục /tmp
    wget --quiet --show-progress -O "${CF_DEB_FILE}" "${CF_DOWNLOAD_URL}"

    echo ">>> Cài đặt Cloudflared từ file .deb..."
    # Cài đặt gói .deb bằng dpkg
    dpkg -i "${CF_DEB_FILE}" || apt-get install -f -y # Chạy dpkg, nếu lỗi dependency thì chạy apt-get -f để sửa
    # Chạy lại dpkg -i phòng trường hợp apt-get -f chỉ cài dependency mà chưa cấu hình xong gói cloudflared
    dpkg -i "${CF_DEB_FILE}"

    echo ">>> Dọn dẹp file cài đặt đã tải..."
    rm -f "${CF_DEB_FILE}"

    echo ">>> Cloudflared đã được cài đặt."
fi

# 6. Đăng ký và khởi chạy Cloudflared service
echo ">>> 6/6: Đăng ký và khởi chạy Cloudflared service..."

echo ">>> Sử dụng token để đăng ký service cloudflared..."
# Lệnh này sẽ:
# - Tạo file cấu hình (thường là /etc/cloudflared/config.yml) nếu chưa có.
# - Lưu trữ chứng chỉ tunnel (thường là /etc/cloudflared/cert.pem).
# - Tạo file systemd service unit (/etc/systemd/system/cloudflared.service).
# - Sử dụng token để liên kết agent này với tunnel trên Cloudflare dashboard.
cloudflared service install "${CF_TOKEN}"

echo ">>> Kích hoạt và khởi động service cloudflared..."
# Kích hoạt service để tự khởi động cùng hệ thống
systemctl enable cloudflared
# Khởi động (hoặc khởi động lại nếu đã chạy trước đó) service ngay lập tức
systemctl start cloudflared

echo ">>> Đợi cloudflared kết nối tới Cloudflare (khoảng 10-15 giây)..."
sleep 15

echo ">>> Kiểm tra trạng thái service cloudflared:"
# Hiển thị trạng thái hiện tại của service, không cần dùng --no-pager vì thường chỉ vài dòng
systemctl status cloudflared

# === HOÀN TẤT ===
echo ""
echo "========================================================"
echo ">>> HOÀN TẤT QUÁ TRÌNH CÀI ĐẶT VÀ CẤU HÌNH <<<"
echo "========================================================"
echo ""
echo "--- Thông tin n8n ---"
echo "* Trạng thái container: Chạy 'sudo docker ps' (Tìm container tên 'n8n')"
echo "* Xem logs n8n: sudo docker logs n8n"
echo "* Xem logs n8n liên tục: sudo docker logs -f n8n"
echo "* Dừng n8n: cd ${N8N_DIR} && sudo docker compose down"
echo "* Khởi động lại n8n: cd ${N8N_DIR} && sudo docker compose up -d"
echo "* Thư mục cấu hình và dữ liệu n8n: ${N8N_DATA_DIR}"
echo "* Truy cập nội bộ (từ Orange Pi): http://127.0.0.1:5678"
echo ""
echo "--- Thông tin Cloudflare Tunnel ---"
echo "* Trạng thái service: Chạy 'sudo systemctl status cloudflared'"
echo "* Xem logs cloudflared: sudo journalctl -u cloudflared -f --no-pager"
echo "* Khởi động lại service: sudo systemctl restart cloudflared"
echo "* File cấu hình tunnel: /etc/cloudflared/config.yml (thường được tạo tự động)"
echo "* Chứng chỉ tunnel: /etc/cloudflared/cert.pem"
echo ""
echo "--- Bước Tiếp Theo QUAN TRỌNG ---"
echo "1. Đăng nhập vào Cloudflare Zero Trust Dashboard."
echo "2. Đi tới mục 'Access' -> 'Tunnels'."
echo "3. Tìm Tunnel có tên 'n8n-Doanh' hoặc ID '173a57b7-20e9-4d24-8b7d-7bc0f4c15583'."
echo "4. Chuyển qua tab 'Public Hostnames'."
echo "5. Đảm bảo bạn có một dòng cấu hình:"
echo "   - Subdomain/Hostname: n8n"
echo "   - Domain: doanh.id.vn"
echo "   - Path: (để trống)"
echo "   - Service Type: HTTP"
echo "   - Service URL: http://localhost:5678"
echo "6. Nếu chưa có, hãy tạo mới cấu hình Public Hostname như trên."
echo ""
echo ">>> Sau khi cấu hình đúng trên Cloudflare Dashboard, bạn sẽ có thể truy cập n8n qua:"
echo ">>> https://n8n.doanh.id.vn"
echo ""
if [ -n "$SUDO_USER" ]; then
    echo ">>> NHẮC NHỞ: Đăng xuất và đăng nhập lại với người dùng '$SUDO_USER' để có thể chạy lệnh 'docker' mà không cần 'sudo'."
fi
echo "========================================================"

exit 0
