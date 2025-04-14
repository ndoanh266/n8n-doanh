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
# Lấy phần subdomain từ N8N_DOMAIN
SUBDOMAIN=$(echo "$N8N_DOMAIN" | cut -d'.' -f1)
echo "  Tên: ${SUBDOMAIN}  (Chỉ phần tên miền phụ, ví dụ: 'n8n')"
echo "  Nội dung (Target): <ID của Tunnel của bạn>.cfargotunnel.com"
echo "  Proxy status: Proxied (Đám mây màu cam)"
echo "Bạn có thể tìm ID Tunnel trong trang Cloudflare Zero Trust -> Access -> Tunnels."
read -p "Nhấn Enter để tiếp tục sau khi đã cấu hình DNS..."

echo "==== BẮT ĐẦU THIẾT LẬP N8N ===="

# Unmask Docker services
echo "Đang khởi tạo hệ thống Docker..."
sudo apt update > /dev/null 2>&1
# Đảm bảo các gói cần thiết được cài đặt
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin curl > /dev/null 2>&1 || { echo "Lỗi: Không thể cài đặt các gói Docker cần thiết."; exit 1; }

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
# Xem thêm tại: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/configuration/
tunnel: ${TUNNEL_NAME}
credentials-file: /etc/cloudflared/${TUNNEL_NAME}.json # Mặc định cloudflared sẽ tìm token trong file này khi dùng command `run <Tên tunnel>`

ingress:
  - hostname: ${N8N_DOMAIN}
    service: http://n8n:5678 # Trỏ đến service n8n trong cùng Docker network
  # Quy tắc bắt buộc cuối cùng để chặn các yêu cầu không khớp hostname
  - service: http_status:404
EOF

# Create docker-compose.yml
echo "Đang tạo file docker-compose.yml..."
# Sử dụng docker compose plugin mới (v2) thay vì docker-compose (v1)
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
    # --- Lệnh chạy tunnel sử dụng token ---
    # Cloudflared sẽ tự động tạo file credentials nếu chưa có và dùng token
    command: tunnel --no-autoupdate run --token ${CF_TOKEN} ${TUNNEL_NAME}
    # --- Không cần mount config.yml nếu bạn dùng command 'run --token <TOKEN> <NAME>'
    #     vì ingress rules sẽ được quản lý qua Cloudflare Dashboard hoặc API
    # volumes:
    #   - ./.cloudflared:/etc/cloudflared
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
if [ $? -ne 0 ]; then
    echo "Lỗi: docker compose up -d thất bại. Vui lòng kiểm tra log."
    sudo docker compose logs
    exit 1
fi

# Kiểm tra trạng thái container sau một khoảng thời gian chờ
echo "Đợi các container khởi động (khoảng 30 giây)..."
sleep 30 # Tăng thời gian chờ cho n8n và postgres khởi động hoàn toàn

echo "==== TRẠNG THÁI CONTAINER ===="
sudo docker compose ps

# Hiển thị log của cloudflared để kiểm tra kết nối tunnel và định tuyến
echo "==== LOGS CLOUDFLARED (Kiểm tra kết nối Tunnel) ===="
sudo docker compose logs --tail=50 cloudflared # Hiển thị 50 dòng log cuối

# Quay lại thư mục gốc (nếu cần)
cd ..

echo "==== THIẾT LẬP N8N HOÀN TẤT ===="
echo "N8N (nếu mọi thứ thành công) nên có thể truy cập tại: https://${N8N_DOMAIN}"
echo "Nếu không truy cập được, hãy kiểm tra:"
echo "  1. Cấu hình CNAME trong Cloudflare DNS đã đúng và được proxy (đám mây màu cam)."
echo "  2. Tên Tunnel (${TUNNEL_NAME}) và Token đã nhập chính xác."
echo "  3. Log của container 'cloudflared' xem có báo lỗi kết nối không (lệnh: sudo docker compose -f $BASE_DIR/docker-compose.yml logs cloudflared)."
echo "  4. Log của container 'n8n' xem có lỗi khởi động không (lệnh: sudo docker compose -f $BASE_DIR/docker-compose.yml logs n8n)."
echo ""
echo "Tài khoản đăng nhập N8N:"
echo "  Username: admin"
echo "  Password: changeme123 (!!! HÃY ĐỔI MẬT KHẨU NGAY TRONG CÀI ĐẶT N8N !!!)"
echo "--------------------------------------------------"

# --- Phần giữ session (Tùy chọn) ---
echo "==== SCRIPT TỰ ĐỘNG GIỮ SESSION (Tùy chọn) ===="
echo "Phần này giúp mô phỏng hoạt động để ngăn một số môi trường Cloud Shell/VNC tự động ngắt kết nối do không hoạt động."
read -p "Bạn có muốn thiết lập script giữ session không? (y/N): " SETUP_MONITOR
if [[ "$SETUP_MONITOR" =~ ^[Yy]$ ]]; then
    # Hỏi URL để ping. URL này nên là một URL ít thay đổi và luôn sẵn sàng.
    # Có thể là URL VNC, URL trang quản lý của cloud provider, hoặc thậm chí là một dịch vụ uptime monitor.
    read -p "Nhập URL remote để ping (ví dụ: URL VNC, URL trang quản lý, hoặc URL endpoint của Uptime Kuma/Better Uptime): " MONITOR_URL

    if [ -z "$MONITOR_URL" ]; then
        echo "Lỗi: URL không được để trống! Bỏ qua thiết lập giữ session."
    else
        echo "Đang cài đặt các gói cần thiết (curl)..."
        # Đảm bảo curl đã được cài ở trên
        # Có thể cân nhắc cài caffeine nếu muốn ngăn cả máy tính sleep, nhưng cron job thường đủ để giữ session shell/vnc
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

# Thực hiện curl với timeout 15 giây kết nối, tối đa 30 giây tổng cộng và ghi kết quả
# -L: theo dõi chuyển hướng (nếu có)
# -s: im lặng
# -o /dev/null: bỏ qua output thành công
# -w '%{http_code}': chỉ in mã trạng thái HTTP
# --connect-timeout: thời gian chờ tối đa để thiết lập kết nối
# --max-time: thời gian chờ tối đa cho toàn bộ hoạt động
http_code=\$(curl -L -s -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 "\$URL")
curl_status=\$? # Lấy mã thoát của lệnh curl

if [ \$curl_status -eq 0 ] && [[ "\$http_code" == 2* || "\$http_code" == 3* ]]; then
    # Mã thoát 0 và HTTP code 2xx hoặc 3xx được coi là thành công
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - Successfully pinged \$URL - HTTP Status: \$http_code" >> "\$LOG_FILE"
else
    # Ghi log lỗi chi tiết hơn
    error_msg="\$(curl -L -s --connect-timeout 15 --max-time 30 "\$URL" 2>&1)" # Chạy lại để lấy output lỗi
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - Failed to ping \$URL - Curl Exit Status: \$curl_status - HTTP Status: \$http_code - Error: \$error_msg" >> "\$LOG_FILE"
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
            # Xóa job cũ nếu có và thêm job mới để chạy mỗi 5 phút
            (crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT_PATH" ; echo "*/5 * * * * $MONITOR_SCRIPT_PATH") | crontab -
            if [ $? -ne 0 ]; then
                echo "Lỗi: Không thể cập nhật crontab. Vui lòng chạy lệnh sau thủ công:"
                echo "1. Chạy 'crontab -e'"
                echo "2. Xóa dòng cũ liên quan đến $MONITOR_SCRIPT_PATH (nếu có)"
                echo "3. Thêm dòng mới: */5 * * * * $MONITOR_SCRIPT_PATH"
            else
                 echo "Đã thêm vào crontab để chạy mỗi 5 phút."
                 # Nếu bạn thực sự cần ngăn máy tính ngủ, hãy bỏ comment dòng dưới
                 # echo "Đang chạy caffeine trong nền (nếu đã cài đặt)..."
                 # sudo nohup caffeine > /dev/null 2>&1 & disown
            fi
        fi
    fi
else
    echo "Bỏ qua thiết lập script giữ session."
fi

echo "==== HOÀN TẤT TOÀN BỘ SCRIPT ===="
