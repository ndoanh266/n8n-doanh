#!/bin/bash

# --- Lấy thông tin cần thiết từ người dùng ---
echo "==== CẤU HÌNH CLOUDFLARE TUNNEL ===="
read -p "Nhập tên Cloudflare Tunnel của bạn (ví dụ: n8n-Doanh): " TUNNEL_NAME
# Sử dụng tên mặc định nếu người dùng không nhập gì
if [ -z "$TUNNEL_NAME" ]; then
    TUNNEL_NAME="n8n-Doanh" # Đặt tên mặc định nếu bạn muốn
    echo "Sử dụng tên Tunnel mặc định: $TUNNEL_NAME"
fi

# Nhắc nhập token một cách an toàn (không hiển thị trên màn hình)
read -sp "Nhập Cloudflare Tunnel Token của bạn (Token cho Tunnel '$TUNNEL_NAME'): " CF_TOKEN
echo # Thêm dòng mới sau khi nhập xong token

if [ -z "$CF_TOKEN" ]; then
    echo "Lỗi: Cloudflare Tunnel Token không được để trống!"
    exit 1
fi

# Xác định tên miền từ tên tunnel hoặc hỏi người dùng (Giả định là n8n.doanh.id.vn)
# Nếu bạn muốn linh hoạt hơn, có thể hỏi tên miền ở đây
PUBLIC_HOSTNAME="n8n.doanh.id.vn"
echo "Sử dụng tên miền công khai: $PUBLIC_HOSTNAME"

echo "==== BẮT ĐẦU THIẾT LẬP N8N ===="

# Unmask Docker services
echo "Đang khởi tạo hệ thống Docker..."
# Kiểm tra và cài đặt Docker và Docker Compose nếu chưa có
if ! command -v docker &> /dev/null; then
    echo "Docker chưa được cài đặt. Đang cài đặt Docker..."
    sudo apt update > /dev/null 2>&1
    sudo apt install -y apt-transport-https ca-certificates curl software-properties-common > /dev/null 2>&1
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg > /dev/null 2>&1
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update > /dev/null 2>&1
    sudo apt install -y docker-ce docker-ce-cli containerd.io > /dev/null 2>&1
    sudo usermod -aG docker $USER # Thêm user hiện tại vào group docker
    echo "Đã cài đặt Docker. Bạn có thể cần đăng xuất và đăng nhập lại để thay đổi nhóm có hiệu lực."
else
    echo "Docker đã được cài đặt."
fi

if ! command -v docker-compose &> /dev/null; then
     # Cài đặt Docker Compose v1 (cách cũ nhưng vẫn hoạt động)
     # echo "Docker Compose chưa được cài đặt. Đang cài đặt Docker Compose v1..."
     # LATEST_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
     # sudo curl -L "https://github.com/docker/compose/releases/download/${LATEST_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
     # sudo chmod +x /usr/local/bin/docker-compose

     # Cài đặt Docker Compose v2 (plugin) - Cách khuyến nghị
     echo "Docker Compose chưa được cài đặt. Đang cài đặt Docker Compose v2 plugin..."
     sudo apt update > /dev/null 2>&1
     sudo apt install -y docker-compose-plugin > /dev/null 2>&1
else
     echo "Docker Compose đã được cài đặt."
fi

# Đảm bảo dịch vụ Docker đang chạy
echo "Đảm bảo Docker đang chạy và được kích hoạt..."
sudo systemctl unmask docker.service > /dev/null 2>&1 || true
sudo systemctl unmask docker.socket > /dev/null 2>&1 || true
sudo systemctl start docker > /dev/null 2>&1
sudo systemctl enable docker > /dev/null 2>&1

# Create directories
echo "Đang tạo thư mục làm việc..."
BASE_DIR="$HOME/n8n-docker" # Sử dụng thư mục trong home user thay vì gốc
sudo mkdir -p "$BASE_DIR/n8n_data"
sudo mkdir -p "$BASE_DIR/postgres_data"

# Set permissions - Cấp quyền cho user hiện tại để không cần sudo khi chạy docker-compose sau này
echo "Đang thiết lập quyền cho thư mục..."
sudo chown -R $(id -u):$(id -g) "$BASE_DIR"
chmod -R 770 "$BASE_DIR" # Quyền hợp lý hơn 777

# Create docker-compose.yml
echo "Đang tạo file docker-compose.yml tại $BASE_DIR/docker-compose.yml..."
# Sử dụng cat << EOF để thay thế biến
cat << EOF > "$BASE_DIR/docker-compose.yml"
version: '3.7' # Nên chỉ định version
services:
  postgres:
    image: postgres:15
    container_name: n8n_postgres
    restart: always
    environment:
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: n8npass # !!! Nên đổi mật khẩu này !!!
      POSTGRES_DB: n8ndb
    volumes:
      - postgres_data:/var/lib/postgresql/data # Sử dụng named volume
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8ndb"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - n8n_internal_network

  n8n:
    image: n8nio/n8n:latest # Sử dụng tag latest hoặc phiên bản cụ thể
    container_name: n8n
    restart: always
    ports:
      - "127.0.0.1:5678:5678" # Chỉ expose port cho localhost (cho cloudflared kết nối)
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres # Tên service của postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8ndb
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=n8npass # !!! Phải khớp với POSTGRES_PASSWORD ở trên !!!
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=changeme123 # !!! NHỚ ĐỔI MẬT KHẨU NÀY SAU KHI ĐĂNG NHẬP !!!
      - N8N_HOST=${PUBLIC_HOSTNAME} # Sử dụng biến tên miền đã xác định
      - N8N_PORT=5678
      - N8N_PROTOCOL=https # Cloudflare xử lý SSL
      - TZ=Asia/Ho_Chi_Minh # Đặt múi giờ
      - WEBHOOK_URL=https://${PUBLIC_HOSTNAME}/ # Quan trọng cho webhook
      - NODE_FUNCTION_ALLOW_EXTERNAL=lodash,moment # Ví dụ: cho phép một số module node phổ biến
      # - EXECUTIONS_DATA_PRUNE=true # Tự động xóa dữ liệu thực thi cũ
      # - EXECUTIONS_DATA_MAX_AGE=30 # Giữ dữ liệu trong 30 ngày
    volumes:
      - n8n_data:/home/node/.n8n # Sử dụng named volume
    depends_on:
      postgres:
        condition: service_healthy # Chờ postgres sẵn sàng
    networks:
      - n8n_internal_network

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared-tunnel-${TUNNEL_NAME} # Đặt tên container rõ ràng
    restart: always
    depends_on:
      - n8n # Đảm bảo n8n chạy trước khi tunnel kết nối
    command: tunnel --no-autoupdate run --token ${CF_TOKEN} # Token sẽ được nhúng vào đây
    # Tunnel ID/Name được lấy từ token hoặc bạn có thể chỉ định rõ ràng nếu cần
    # command: tunnel --no-autoupdate run --token ${CF_TOKEN} ${TUNNEL_NAME} # Chỉ định rõ tên Tunnel
    networks:
      - n8n_internal_network # Chỉ cần kết nối tới network nội bộ này

volumes: # Định nghĩa named volumes
  n8n_data:
    name: n8n_data_volume # Đặt tên cụ thể cho volume
  postgres_data:
    name: postgres_data_volume # Đặt tên cụ thể cho volume

networks: # Định nghĩa network riêng
  n8n_internal_network:
    name: n8n_network
    driver: bridge # Sử dụng bridge network mặc định là đủ
EOF

# Chạy docker-compose
echo "Đang khởi chạy các container (n8n, postgres, cloudflared) trong nền..."
# Chuyển vào thư mục chứa docker-compose.yml
cd "$BASE_DIR" || { echo "Lỗi: Không thể chuyển vào thư mục $BASE_DIR"; exit 1; }

# Sử dụng docker compose (v2) hoặc docker-compose (v1) tùy theo cái nào tồn tại
if command -v docker compose &> /dev/null; then
    docker compose up -d
else
    docker-compose up -d
fi

# Kiểm tra trạng thái container sau vài giây
echo "Đợi các container khởi động (khoảng 30 giây)..."
sleep 30

echo "==== TRẠNG THÁI CONTAINER ===="
if command -v docker compose &> /dev/null; then
    docker compose ps
else
    docker-compose ps
fi

# Hiển thị log của cloudflared để kiểm tra kết nối tunnel
echo "==== LOGS CLOUDFLARED (Kiểm tra kết nối Tunnel - Ctrl+C để thoát xem log) ===="
if command -v docker compose &> /dev/null; then
    docker compose logs -f cloudflared
else
    docker-compose logs -f cloudflared
fi
# Đoạn này sẽ tiếp tục chạy nếu bạn nhấn Ctrl+C để dừng xem log

# Quay lại thư mục trước đó nếu cần (không thực sự cần thiết ở cuối script)
# cd - > /dev/null

echo "==== THIẾT LẬP CƠ BẢN HOÀN TẤT ===="
echo "N8N nên có thể truy cập tại: https://${PUBLIC_HOSTNAME}"
echo "Tài khoản đăng nhập N8N:"
echo "  Username: admin"
echo "  Password: changeme123 (!!! HÃY ĐỔI MẬT KHẨU NGAY SAU KHI ĐĂNG NHẬP LẦN ĐẦU !!!)"
echo "--------------------------------------------------"
echo "Thư mục chứa dữ liệu và cấu hình: $BASE_DIR"
echo "Để dừng n8n: cd $BASE_DIR && docker compose down"
echo "Để khởi động lại: cd $BASE_DIR && docker compose up -d"
echo "Để xem logs: cd $BASE_DIR && docker compose logs -f <tên_service>"
echo "--------------------------------------------------"

# --- Phần giữ session (giữ nguyên hoặc xóa nếu không cần) ---
# ... (Giữ nguyên phần này nếu bạn vẫn muốn dùng nó) ...
# Hoặc xóa hoàn toàn nếu không cần thiết nữa

echo "==== HOÀN TẤT ===="
