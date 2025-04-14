#!/bin/bash

# --- Lấy thông tin cần thiết từ người dùng ---
echo "==== CẤU HÌNH CLOUDFLARE TUNNEL ===="
read -p "Nhập tên Cloudflare Tunnel của bạn (ví dụ: n8n-Doanh): " TUNNEL_NAME
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
sudo mkdir -p docker-run/n8n_data
sudo mkdir -p docker-run/postgres_data

# Set permissions
echo "Đang thiết lập quyền..."
sudo chmod -R 777 docker-run
# Lưu ý: Cấp quyền 777 không phải lúc nào cũng là tốt nhất về bảo mật, nhưng nó giải quyết vấn đề quyền phổ biến với Docker volumes.
# Cân nhắc sử dụng user mapping hoặc quyền cụ thể hơn nếu cần bảo mật cao hơn.
# sudo chown -R $(id -u):$(id -g) docker-run # Một cách khác an toàn hơn nếu user hiện tại chạy docker

# Create docker-compose.yml
echo "Đang tạo file docker-compose.yml..."
# Sử dụng cat << EOF thay vì cat << 'EOF' để cho phép thay thế biến $TUNNEL_NAME và $CF_TOKEN
cat << EOF > docker-run/docker-compose.yml
version: '3.7' # Nên chỉ định version
services:
  postgres:
    image: postgres:15
    container_name: n8n_postgres
    restart: always
    environment:
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: n8npass
      POSTGRES_DB: n8ndb
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    healthcheck: # Thêm kiểm tra sức khỏe cho postgres
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8ndb"]
      interval: 10s
      timeout: 5s
      retries: 5

  n8n:
    image: n8nio/n8n
    container_name: n8n
    restart: always
    ports:
      - "127.0.0.1:5678:5678" # Chỉ expose port cho localhost để cloudflared kết nối
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8ndb
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=n8npass
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=changeme123 # !!! NHỚ ĐỔI MẬT KHẨU NÀY !!!
      - N8N_HOST=n8n.doanh.id.vn # !!! SỬ DỤNG DOMAIN CÔNG KHAI CỦA BẠN !!!
      - N8N_PORT=5678
      - N8N_PROTOCOL=https # Vì Cloudflare sẽ xử lý SSL
      - TZ=Asia/Ho_Chi_Minh
      - WEBHOOK_URL=https://n8n.doanh.id.vn/ # Quan trọng cho webhook
      # - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh # Có thể cần cho một số node
    volumes:
      - ./n8n_data:/home/node/.n8n
    depends_on:
      postgres: # Đảm bảo postgres sẵn sàng
        condition: service_healthy

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared-tunnel-${TUNNEL_NAME} # Đặt tên container rõ ràng hơn
    restart: always
    depends_on:
      - n8n # Đảm bảo n8n chạy trước khi tunnel kết nối
    command: tunnel --no-autoupdate run --token ${CF_TOKEN} ${TUNNEL_NAME}
    # Lưu ý: Token được nhúng trực tiếp vào đây khi file được tạo ra.
    # Nếu bạn muốn an toàn hơn, hãy dùng secrets hoặc environment variables từ file .env

volumes: # Định nghĩa volumes rõ ràng
  n8n_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: $PWD/docker-run/n8n_data # Sử dụng đường dẫn tuyệt đối để tránh lỗi
  postgres_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: $PWD/docker-run/postgres_data # Sử dụng đường dẫn tuyệt đối

networks: # Nên định nghĩa network riêng
  default:
    name: n8n_network
EOF

# Run docker compose without output initially
echo "Đang khởi chạy các container (n8n, postgres, cloudflared)..."
# Chuyển vào thư mục chứa docker-compose.yml để Docker hiểu context và volumes
cd docker-run || exit 1 # Thoát nếu không chuyển được thư mục
sudo docker compose up -d # Không cần chỉ định -f nếu đang ở đúng thư mục

# Kiểm tra trạng thái container sau vài giây
echo "Đợi các container khởi động..."
sleep 15 # Cho thời gian khởi động

echo "==== TRẠNG THÁI CONTAINER ===="
sudo docker compose ps

# Hiển thị log của cloudflared để kiểm tra kết nối tunnel
echo "==== LOGS CLOUDFLARED (Kiểm tra kết nối Tunnel) ===="
sudo docker compose logs cloudflared

# Quay lại thư mục gốc (nếu cần)
cd ..

echo "==== THIẾT LẬP HOÀN TẤT ===="
echo "N8N nên có thể truy cập tại: https://n8n.doanh.id.vn"
echo "Tài khoản đăng nhập N8N:"
echo "  Username: admin"
echo "  Password: changeme123 (!!! HÃY ĐỔI MẬT KHẨU NGAY !!!)"
echo "--------------------------------------------------"

# --- Phần giữ session (giữ nguyên nếu bạn cần) ---
echo "==== SCRIPT TỰ ĐỘNG GIỮ SESSION (Tùy chọn) ===="
# Kiểm tra xem người dùng có muốn thiết lập không
read -p "Bạn có muốn thiết lập script giữ session không? (y/N): " SETUP_MONITOR
if [[ "$SETUP_MONITOR" =~ ^[Yy]$ ]]; then
    read -p "Nhập URL remote để ping (ví dụ: https://...): " MONITOR_URL

    # Kiểm tra nếu URL trống
    if [ -z "$MONITOR_URL" ]; then
        echo "Lỗi: URL không được để trống! Bỏ qua thiết lập giữ session."
    else
        echo "Đang cài đặt caffeine..."
        sudo apt update > /dev/null 2>&1
        sudo apt install -y caffeine > /dev/null 2>&1

        echo "Đang tạo file /home/user/monitor.sh..."
        # Tạo thư mục nếu chưa có và đảm bảo user có quyền ghi
        sudo mkdir -p /home/user
        sudo chown $(whoami):$(whoami) /home/user # Cấp quyền cho user hiện tại

        cat > /home/user/monitor.sh << EOL
#!/bin/bash
# URL cần kết nối
URL="$MONITOR_URL"
# Kết nối đến URL và ghi log
curl -s --connect-timeout 10 "\$URL" > /dev/null 2>&1
LOG_FILE="/home/user/vnc_monitor.log"
echo "\$(date '+%Y-%m-%d %H:%M:%S') - Pinged \$URL - Status: \$?" >> "\$LOG_FILE"
# Giữ log file không quá lớn (giữ 1000 dòng cuối cùng)
tail -n 1000 "\$LOG_FILE" > "\$LOG_FILE.tmp" && mv "\$LOG_FILE.tmp" "\$LOG_FILE"
EOL

        echo "Đang cấp quyền thực thi cho script monitor.sh..."
        sudo chmod +x /home/user/monitor.sh
        if [ $? -ne 0 ]; then
            echo "Lỗi: Không thể cấp quyền thực thi. Vui lòng chạy lệnh sau thủ công:"
            echo "sudo chmod +x /home/user/monitor.sh"
        else
            echo "Đang thêm script vào crontab để chạy mỗi 5 phút..."
            (crontab -l 2>/dev/null | grep -v "/home/user/monitor.sh" ; echo "*/5 * * * * /home/user/monitor.sh") | crontab -
            if [ $? -ne 0 ]; then
                echo "Lỗi: Không thể cập nhật crontab. Vui lòng chạy lệnh sau thủ công:"
                echo "'crontab -e' và thêm dòng: */5 * * * * /home/user/monitor.sh"
            else
                 echo "Đã thêm vào crontab."
                 # Chạy caffeine trong nền
                 echo "Đang chạy caffeine trong nền..."
                 sudo nohup caffeine > /dev/null 2>&1 &
            fi
        fi
    fi
else
    echo "Bỏ qua thiết lập script giữ session."
fi

echo "==== HOÀN TẤT ===="
