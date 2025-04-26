#!/bin/bash
set -e # Thoát ngay nếu có lỗi

echo "--------- 🟢 [Bước 1/6] Gỡ bỏ cấu hình Docker cũ và các gói liên quan -----------"
sudo rm -f /etc/apt/sources.list.d/archive_uri-https_download_docker_com_linux_ubuntu-jammy.list
# Cố gắng xóa key cũ, bỏ qua lỗi nếu không tìm thấy
sudo apt-key del $(sudo apt-key list | grep -B 1 docker | head -n 1 | cut -d'/' -f2 | cut -d' ' -f1) > /dev/null 2>&1 || true
sudo apt-get remove --purge docker docker-engine docker.io containerd runc -y || true # Gỡ bỏ các gói cũ, bỏ qua lỗi nếu chưa cài
sudo apt-get autoremove -y
sudo apt-get clean
sudo rm -rf /var/lib/docker # Xóa dữ liệu docker cũ (cẩn thận nếu có dữ liệu quan trọng khác)
sudo rm -rf /etc/docker
sudo apt update

echo "--------- 🟢 [Bước 2/6] Cài đặt Docker đúng cách cho arm64 -----------"
# Cài đặt các gói cần thiết
sudo apt-get install -y ca-certificates curl gnupg
# Thêm khóa GPG chính thức của Docker
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
# Thiết lập kho lưu trữ Docker
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
# Cài đặt Docker Engine, CLI, Compose
sudo apt-get update
# Đảm bảo không có lỗi về gói trước khi cài đặt
sudo apt --fix-broken install -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
# Thêm người dùng vào nhóm docker
sudo usermod -aG docker $USER
# Sửa lỗi dấu chấm than bằng cách đặt trong dấu nháy đơn
echo '(!) QUAN TRỌNG: Bạn cần ĐĂNG XUẤT và ĐĂNG NHẬP lại sau khi script này hoàn tất để chạy lệnh "docker" không cần "sudo".'

echo "--------- 🟢 [Bước 3/6] Chuẩn bị thư mục và file cấu hình n8n -----------"
cd ~
mkdir -p vol_localai vol_n8n
# Đảm bảo quyền sở hữu đúng ngay cả khi chạy bằng sudo
CURRENT_USER=$(whoami)
CURRENT_GROUP=$(id -gn $CURRENT_USER)
sudo chown -R 1000:1000 vol_localai # n8n thường chạy với user id 1000
sudo chown -R $USER:$CURRENT_GROUP vol_n8n # Hoặc cấp quyền cho user hiện tại nếu cần truy cập dễ dàng
sudo chmod -R 755 vol_localai vol_n8n
# Tải file compose nếu chưa có
if [ ! -f compose.yaml ]; then
    echo "Đang tải compose.yaml..."
    wget https://raw.githubusercontent.com/thangnch/MIAI_n8n_dockercompose/refs/heads/main/compose.yaml -O compose.yaml
else
    echo "File compose.yaml đã tồn tại."
fi

echo "--------- 🟢 [Bước 4/6] Khởi động n8n bằng Docker Compose -----------"
# Đặt biến môi trường rõ ràng
export EXTERNAL_IP="http://$(hostname -I | awk '{print $1}')" # Lấy IP đầu tiên
export CURR_DIR=$(pwd)
echo "Sử dụng EXTERNAL_IP=${EXTERNAL_IP}"
echo "Sử dụng CURR_DIR=${CURR_DIR}"

# Chạy compose với biến môi trường đã export và sử dụng sudo
# Dừng các container cũ (nếu có) trước khi khởi động lại
sudo docker compose down || true # Bỏ qua lỗi nếu chưa có gì chạy
sudo -E docker compose up -d # Sử dụng -E để giữ lại biến môi trường đã export

echo "Đang đợi n8n khởi động..."
sleep 20 # Chờ lâu hơn một chút

# Kiểm tra container n8n
echo "Kiểm tra container n8n đang chạy:"
sudo docker ps | grep n8n || echo "Cảnh báo: Container n8n có thể chưa chạy hoặc có tên khác."

echo "--------- 🟢 [Bước 5/6] Cài đặt và cấu hình Cloudflare Tunnel (cloudflared) -----------"
# Gỡ cài đặt cloudflared cũ (nếu có) để đảm bảo cài mới sạch sẽ
sudo systemctl stop cloudflared || true
sudo apt-get remove cloudflared -y || true
sudo rm -f /etc/apt/sources.list.d/cloudflared.list*
sudo rm -f /usr/share/keyrings/cloudflare-main.gpg
sudo apt update

# Tải cloudflared cho arm64
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "arm64" ]; then
    CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"
elif [ "$ARCH" = "armhf" ] || [ "$ARCH" = "armel" ]; then
     CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm.deb"
else
    echo "Lỗi: Kiến trúc không được hỗ trợ: $ARCH. Chỉ hỗ trợ arm64 và arm."
    exit 1
fi
echo "Đang tải cloudflared cho $ARCH..."
curl -L --output cloudflared.deb $CLOUDFLARED_URL
# Cài đặt cloudflared
sudo dpkg -i cloudflared.deb || (sudo apt --fix-broken install -y && sudo dpkg -i cloudflared.deb)

# Cài đặt service cloudflared bằng token
echo "Đang cài đặt dịch vụ cloudflared với token..."
sudo cloudflared service install eyJhIjoiZWNhMjg3MTJiZjY0N2I2ZmYyNDBkZjU4MjZlNWNkOTYiLCJ0IjoiMTczYTU3YjctMjBlOS00ZDI0LThiN2QtN2JjMGY0YzE1NTgzIiwicyI6Ik1qazROekkzWmpjdE5UWXlNaTAwTldWaExUaGhaV010WXpaaVpEQXhNakF4TnpkaSJ9

# Tạo thư mục cấu hình nếu chưa tồn tại
sudo mkdir -p /etc/cloudflared/

# Tạo file cấu hình /etc/cloudflared/config.yml
# Đảm bảo cổng 5678 là đúng cho n8n của bạn (kiểm tra file compose.yaml)
N8N_PORT=$(grep -A 5 "services:" compose.yaml | grep "n8n:" -A 3 | grep "ports:" -A 1 | tail -n 1 | awk -F ':' '{print $1}' | sed 's/[" \t-]//g')
if [ -z "$N8N_PORT" ]; then
    echo "Cảnh báo: Không thể tự động xác định cổng n8n từ compose.yaml. Sử dụng cổng mặc định 5678."
    N8N_PORT=5678
fi
echo "Sử dụng cổng n8n: $N8N_PORT"

echo "Đang tạo file cấu hình /etc/cloudflared/config.yml..."
sudo bash -c 'cat << EOF > /etc/cloudflared/config.yml
# File cấu hình được quản lý bởi systemd service khi cài đặt bằng token.
# Các cài đặt trong file này sẽ ghi đè hoặc bổ sung cấu hình từ service.
# Tunnel ID và credentials file thường được lấy tự động từ service.

# URL của dịch vụ n8n cục bộ
# url: http://localhost:'$N8N_PORT' # Cấu hình này không cần thiết nếu dùng ingress

logfile: /var/log/cloudflared.log
loglevel: info

ingress:
  - hostname: n8n.doanh.id.vn
    service: http://localhost:'$N8N_PORT' # Định tuyến tới n8n
  # Quy tắc cuối cùng: Bắt buộc phải có để tunnel hoạt động đúng
  - service: http_status:404
EOF'

echo "--------- 🟢 [Bước 6/6] Khởi động và kiểm tra dịch vụ cloudflared -----------"
sudo systemctl enable --now cloudflared
echo "Đang đợi dịch vụ cloudflared khởi động..."
sleep 10 # Chờ lâu hơn một chút để service ổn định
sudo systemctl status cloudflared

echo "--------- ✅ HOÀN TẤT! -----------"
echo "1. Docker và n8n đã được cài đặt và (hy vọng) khởi chạy."
echo "2. Cloudflare Tunnel đã được cài đặt và cấu hình để trỏ https://n8n.doanh.id.vn đến n8n cục bộ (cổng $N8N_PORT)."
echo "3. Hãy thử truy cập https://n8n.doanh.id.vn từ trình duyệt của bạn sau vài phút."
echo '4. NHỚ: Đăng xuất và đăng nhập lại vào Orange Pi để có thể sử dụng lệnh "docker" mà không cần "sudo".'
