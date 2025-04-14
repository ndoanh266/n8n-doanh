#!/bin/bash

# --- Lấy thông tin cần thiết từ người dùng ---
echo "==== CẤU HÌNH CLOUDFLARE TUNNEL VÀ N8N ===="
read -p "Nhập tên miền bạn muốn sử dụng cho n8n (ví dụ: n8n.doanh.id.vn): " N8N_DOMAIN
if [ -z "$N8N_DOMAIN" ]; then
    echo "Lỗi: Tên miền không được để trống!"
    exit 1
fi

read -p "Nhập tên Cloudflare Tunnel của bạn (đã tạo trên dashboard Cloudflare, ví dụ: n8n-doanh): " TUNNEL_NAME
if [ -z "$TUNNEL_NAME" ]; then
    echo "Lỗi: Tên Tunnel không được để trống!"
    exit 1
fi

# Nhắc nhập token một cách an toàn (không hiển thị trên màn hình)
read -sp "Nhập Cloudflare Tunnel Token của bạn: " CF_TOKEN
echo # Thêm dòng mới sau khi nhập xong token

if [ -z "$CF_TOKEN" ]; then
    echo "Lỗi: Cloudflare Tunnel Token không được để trống!"
    exit 1
fi

echo "==== QUAN TRỌNG: CẤU HÌNH DNS TRÊN CLOUDFLARE ===="
echo "Hãy đảm bảo bạn đã tạo một bản ghi CNAME trong Cloudflare DNS:"
echo "  Loại: CNAME"
echo "  Tên: ${N8N_DOMAIN%%.*}  (Chỉ phần tên miền phụ, ví dụ: 'n8n' nếu tên miền là 'n8n.doanh.id.vn')"
echo "  Nội dung (Target): <ID của Tunnel của bạn>.cfargotunnel.com"
echo "  Proxy status: Proxied (Đám mây màu cam)"
echo "Bạn có thể tìm ID Tunnel trong trang Cloudflare Zero Trust -> Access -> Tunnels."
read -p "Nhấn Enter để tiếp tục sau khi đã cấu hình DNS..."

echo "==== BẮT ĐẦU THIẾT LẬP N8N ===="

# Unmask Docker services
echo "Đang khởi tạo hệ thống Docker..."
sudo apt update > /dev/null 2>&1
sudo apt install -y docker-compose > /dev/null 2>&1 # Đảm bảo docker-compose được cài đặt
sudo systemctl unmask docker > /dev/null 2>&1
sudo systemctl unmask docker.socket > /dev/null 2>&1
sudo systemctl start docker > /dev/null 2>&1
sudo systemctl start docker.socket > /dev/null 2>&1
sudo systemctl unmask containerd.service > /dev/null 2>&1
sudo systemctl start containerd.service > /dev/null 2>&1
sudo systemctl enable docker > /dev/null 2>&1 # Đảm bảo Docker khởi động cùng hệ thống

# Create directories
echo "Đang tạo thư mục..."
BASE_DIR="docker-run" # Sử dụng biến để dễ quản lý
N8N_DATA_DIR="$BASE_DIR/n8n_data"
POSTGRES_DATA_DIR="$BASE_DIR/postgres_data"
CLOUDFLARED_CONFIG_DIR="$BASE_DIR/.cloudflared" # Thư mục cho cấu hình cloudflared

sudo mkdir -p "$N8N_DATA_DIR"
sudo mkdir -p "$POSTGRES_DATA_DIR"
sudo mkdir -p "$CLOUDFLARED_CONFIG_DIR"

# Set permissions
echo "Đang thiết lập quyền..."
# Lưu ý: Cấp quyền 777 không phải lúc nào cũng là tốt nhất về bảo mật.
# Cân nhắc điều chỉnh quyền sau khi cài đặt nếu cần bảo mật cao hơn.
sudo chmod -R 777 "$BASE_DIR"

# Create cloudflared config.yml
echo "Đang tạo file cấu hình Cloudflared (config.yml)..."
# File này định nghĩa cách tunnel định tuyến lưu lượng truy cập dựa trên hostname
cat << EOF > "$BASE_DIR/.cloudflared/config.yml"
# Định tuyến lưu lượng cho tên miền của bạn đến dịch vụ n8n
ingress:
  - hostname: ${N8N_DOMAIN}
    service: http://n8n:5678 # Trỏ đến service n8n trong cùng Docker network
  # Quy tắc bắt buộc cuối cùng để chặn các yêu cầu không khớp hostname
  - service: http_status:404
EOF

# Create docker-compose.yml
echo "Đang tạo file docker-compose.yml..."
cat << EOF > "$BASE_DIR/docker-compose.yml"
version: '3.7'

services:
  postgres:
    image: postgres:15
    container_name: n8n_postgres
    restart: always
    environment:
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: n8npass # Nên thay đổi mật khẩu này trong môi trường production
      POSTGRES_DB: n8ndb
      TZ: Asia/Ho_Chi_Minh # Thêm múi giờ cho Postgres
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8ndb"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n_network # Thêm vào network

  n8n:
    image: n8nio/n8n
    container_name: n8n
    restart: always
    ports:
      # Chỉ expose cho localhost, cloudflared sẽ kết nối vào đây
      - "127.0.0.1:5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres # Tên service của postgres trong docker-compose
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8ndb
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=n8npass # Phải khớp với POSTGRES_PASSWORD
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=changeme123 # !!! NHỚ ĐỔI MẬT KHẨU NÀY SAU KHI CÀI ĐẶT !!!
      # --- Sử dụng biến N8N_DOMAIN được người dùng nhập ---
      - N8N_HOST=${N8N_DOMAIN}
      - WEBHOOK_URL=https://${N8N_DOMAIN}/ # Quan trọng cho webhook hoạt động đúng
      # --- Các biến khác ---
      - N8N_PORT=5678
      - N8N_PROTOCOL=https # Cloudflare xử lý HTTPS
      - TZ=Asia/Ho_Chi_Minh
      # - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh # Có thể cần cho một số nodes
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - n8n_network # Thêm vào network

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared-tunnel-${TUNNEL_NAME} # Tên container rõ ràng
    restart: always
    depends_on:
      - n8n # Đảm bảo n8n đã chạy (nhưng không cần đợi healthy)
    # --- Lệnh chạy tunnel sử dụng token VÀ config file ---
    # tunnel: tên tunnel đã tạo trên Cloudflare dashboard
    # --config: đường dẫn đến file config bên TRONG container
    # run: chạy tunnel
    # --token: token để xác thực
    command: tunnel --no-autoupdate --config /etc/cloudflared/config.yml run --token ${CF_TOKEN} ${TUNNEL_NAME}
    volumes:
      # Mount thư mục chứa config.yml vào vị trí cloudflared tìm kiếm mặc định
      - ./.cloudflared:/etc/cloudflared
    networks:
      - n8n_network # Thêm vào network

# Sử dụng Docker managed volumes thay vì bind mount với đường dẫn tuyệt đối
# Điều này thường ổn định hơn và Docker quản lý việc tạo thư mục trên host
volumes:
  n8n_data:
  postgres_data:

# Định nghĩa network để các container giao tiếp qua tên service
networks:
  n8n_network:
    driver: bridge
EOF

# Run docker compose
echo "Đang khởi chạy các container (n8n, postgres, cloudflared)..."
# Chuyển vào thư mục chứa docker-compose.yml
cd "$BASE_DIR" || { echo "Lỗi: Không thể chuyển vào thư mục $BASE_DIR"; exit 1; }

# Dừng và xóa các container cũ (nếu có) để tránh xung đột
echo "Đang dừng và xóa các container cũ (nếu có)..."
sudo docker compose down --remove-orphans > /dev/null 2>&1

# Khởi chạy các container trong nền
echo "Đang khởi tạo và chạy các container..."
sudo docker compose up -d

# Kiểm tra trạng thái container sau một khoảng thời gian chờ
echo "Đợi các container khởi động (khoảng 30 giây)..."
sleep 30 # Tăng thời gian chờ cho n8n và postgres khởi động hoàn toàn

echo "==== TRẠNG THÁI CONTAINER ===="
sudo docker compose ps

# Hiển thị log của cloudflared để kiểm tra kết nối tunnel và định tuyến
echo "==== LOGS CLOUDFLARED (Kiểm tra kết nối Tunnel và Ingress Rules) ===="
sudo docker compose logs --tail=50 cloudflared # Hiển thị 50 dòng log cuối

# Quay lại thư mục gốc (nếu cần)
cd ..

echo "==== THIẾT LẬP HOÀN TẤT ===="
echo "N8N (nếu mọi thứ thành công) nên có thể truy cập tại: https://${N8N_DOMAIN}"
echo "Nếu không truy cập được, hãy kiểm tra:"
echo "  1. Cấu hình CNAME trong Cloudflare DNS đã đúng và được proxy."
echo "  2. Log của container 'cloudflared' xem có báo lỗi kết nối hoặc định tuyến không (lệnh: sudo docker compose -f $BASE_DIR/docker-compose.yml logs cloudflared)."
echo "  3. Log của container 'n8n' xem có lỗi khởi động không (lệnh: sudo docker compose -f $BASE_DIR/docker-compose.yml logs n8n)."
echo ""
echo "Tài khoản đăng nhập N8N:"
echo "  Username: admin"
echo "  Password: changeme123 (!!! HÃY ĐỔI MẬT KHẨU NGAY TRONG CÀI ĐẶT N8N !!!)"
echo "--------------------------------------------------"

# --- Phần giữ session (giữ nguyên cấu trúc logic) ---
echo "==== SCRIPT TỰ ĐỘNG GIỮ SESSION (Tùy chọn) ===="
read -p "Bạn có muốn thiết lập script giữ session không? (y/N): " SETUP_MONITOR
if [[ "$SETUP_MONITOR" =~ ^[Yy]$ ]]; then
    read -p "Nhập URL remote để ping (ví dụ: URL của một dịch vụ uptime monitor như Uptime Kuma, Better Uptime,...): " MONITOR_URL

    if [ -z "$MONITOR_URL" ]; then
        echo "Lỗi: URL không được để trống! Bỏ qua thiết lập giữ session."
    else
        echo "Đang cài đặt các gói cần thiết (curl, caffeine - nếu có)..."
        sudo apt update > /dev/null 2>&1
        sudo apt install -y curl > /dev/null 2>&1 # Đảm bảo curl được cài đặt
        # Caffeine có thể không cần thiết nếu chỉ dùng cron job
        # sudo apt install -y caffeine > /dev/null 2>&1

        # Sử dụng thư mục home của user hiện tại
        MONITOR_SCRIPT_PATH="$HOME/monitor_vps.sh"
        MONITOR_LOG_PATH="$HOME/vps_monitor.log"

        echo "Đang tạo file $MONITOR_SCRIPT_PATH..."
        cat > "$MONITOR_SCRIPT_PATH" << EOL
#!/bin/bash
URL="$MONITOR_URL"
LOG_FILE="$MONITOR_LOG_PATH"

# Ghi log thời gian bắt đầu
echo "\$(date '+%Y-%m-%d %H:%M:%S') - Starting ping to \$URL" >> "\$LOG_FILE"

# Thực hiện curl với timeout và ghi kết quả
curl_output=\$(curl -s --connect-timeout 15 --max-time 30 "\$URL" 2>&1)
curl_status=\$?

if [ \$curl_status -eq 0 ]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - Successfully pinged \$URL" >> "\$LOG_FILE"
else
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - Failed to ping \$URL - Status: \$curl_status - Output: \$curl_output" >> "\$LOG_FILE"
fi

# Giữ log file không quá lớn (giữ 1000 dòng cuối cùng)
tail -n 1000 "\$LOG_FILE" > "\$LOG_FILE.tmp" && mv "\$LOG_FILE.tmp" "\$LOG_FILE"

EOL

        echo "Đang cấp quyền thực thi cho script $MONITOR_SCRIPT_PATH..."
        chmod +x "$MONITOR_SCRIPT_PATH"
        if [ $? -ne 0 ]; then
            echo "Lỗi: Không thể cấp quyền thực thi. Vui lòng chạy lệnh sau thủ công:"
            echo "chmod +x $MONITOR_SCRIPT_PATH"
        else
            echo "Đang thêm script vào crontab để chạy mỗi 5 phút..."
            # Xóa job cũ nếu có và thêm job mới
            (crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT_PATH" ; echo "*/5 * * * * $MONITOR_SCRIPT_PATH") | crontab -
            if [ $? -ne 0 ]; then
                echo "Lỗi: Không thể cập nhật crontab. Vui lòng chạy lệnh sau thủ công:"
                echo "'crontab -e' và thêm dòng: */5 * * * * $MONITOR_SCRIPT_PATH"
            else
                 echo "Đã thêm vào crontab."
                 # Không cần chạy caffeine nếu chỉ dùng cron
                 # echo "Đang chạy caffeine trong nền..."
                 # sudo nohup caffeine > /dev/null 2>&1 &
            fi
        fi
    fi
else
    echo "Bỏ qua thiết lập script giữ session."
fi

echo "==== HOÀN TẤT ===="
