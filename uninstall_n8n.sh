#!/bin/bash

echo "====================================================="
echo "           SCRIPT GỠ BỎ N8N VÀ CLOUDFLARED"
echo "====================================================="
echo "CẢNH BÁO: Script này sẽ dừng và xóa các container Docker,"
echo "xóa các file cấu hình, xóa DỮ LIỆU n8n và postgres,"
echo "gỡ bỏ cron job, dừng và gỡ cài đặt caffeine."
echo "Dữ liệu trong các Docker volume sẽ bị MẤT VĨNH VIỄN."
echo "====================================================="
read -p "Bạn có chắc chắn muốn tiếp tục? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Hủy bỏ."
    exit 1
fi

# --- Các biến đường dẫn (phải khớp với script cài đặt) ---
BASE_DIR="docker-run"
MONITOR_SCRIPT_PATH="$HOME/monitor_vps.sh"
MONITOR_LOG_PATH="$HOME/vps_monitor.log"

# --- 1. Dừng và gỡ bỏ các container Docker ---
echo "--> Bước 1: Dừng và gỡ bỏ các container Docker..."
if [ -d "$BASE_DIR" ] && [ -f "$BASE_DIR/docker-compose.yml" ]; then
    echo "Tìm thấy thư mục $BASE_DIR và file docker-compose.yml."
    cd "$BASE_DIR" || { echo "Lỗi: Không thể chuyển vào thư mục $BASE_DIR"; exit 1; }
    echo "Đang chạy 'docker compose down --volumes --remove-orphans'..."
    sudo docker compose down --volumes --remove-orphans
    if [ $? -ne 0 ]; then
        echo "Cảnh báo: 'docker compose down' có thể đã gặp lỗi. Tiếp tục cố gắng dọn dẹp."
    fi
    cd .. # Quay lại thư mục trước đó
    echo "Đã dừng và xóa container, network, và volumes liên quan đến $BASE_DIR/docker-compose.yml."
else
    echo "Không tìm thấy $BASE_DIR/docker-compose.yml. Bỏ qua bước dừng Docker Compose."
    echo "Kiểm tra các volumes Docker thủ công nếu cần: docker-run_n8n_data, docker-run_postgres_data"
fi

# --- 2. Xóa thư mục cấu hình và dữ liệu ---
echo "--> Bước 2: Xóa thư mục $BASE_DIR..."
if [ -d "$BASE_DIR" ]; then
    sudo rm -rf "$BASE_DIR"
    if [ $? -eq 0 ]; then
        echo "Đã xóa thư mục $BASE_DIR."
    else
        echo "Lỗi: Không thể xóa thư mục $BASE_DIR."
    fi
else
    echo "Thư mục $BASE_DIR không tồn tại. Bỏ qua."
fi

# --- 3. Gỡ bỏ Cron job giám sát ---
echo "--> Bước 3: Gỡ bỏ Cron job giám sát..."
if crontab -l | grep -q "$MONITOR_SCRIPT_PATH"; then
    (crontab -l | grep -v "$MONITOR_SCRIPT_PATH") | crontab -
    if [ $? -eq 0 ]; then
        echo "Đã xóa cron job cho $MONITOR_SCRIPT_PATH."
    else
        echo "Lỗi: Không thể xóa cron job. Vui lòng xóa thủ công bằng 'crontab -e'."
    fi
else
    echo "Không tìm thấy cron job cho $MONITOR_SCRIPT_PATH. Bỏ qua."
fi

# --- 4. Xóa script và log giám sát ---
echo "--> Bước 4: Xóa script và file log giám sát..."
if [ -f "$MONITOR_SCRIPT_PATH" ]; then
    rm -f "$MONITOR_SCRIPT_PATH"
    echo "Đã xóa $MONITOR_SCRIPT_PATH."
else
    echo "File $MONITOR_SCRIPT_PATH không tồn tại. Bỏ qua."
fi

if [ -f "$MONITOR_LOG_PATH" ]; then
    rm -f "$MONITOR_LOG_PATH"
    echo "Đã xóa $MONITOR_LOG_PATH."
else
    echo "File $MONITOR_LOG_PATH không tồn tại. Bỏ qua."
fi

# --- 5. Dừng tiến trình caffeine ---
echo "--> Bước 5: Dừng tiến trình caffeine..."
# Sử dụng pkill để tìm và dừng tiến trình caffeine
if pgrep -f "caffeine" > /dev/null; then
    sudo pkill -f "caffeine"
    sleep 2 # Chờ một chút để tiến trình dừng hẳn
    if pgrep -f "caffeine" > /dev/null; then
        echo "Cảnh báo: Không thể dừng tiến trình caffeine bằng pkill. Có thể cần dừng thủ công."
    else
        echo "Đã dừng tiến trình caffeine."
    fi
else
    echo "Không tìm thấy tiến trình caffeine đang chạy. Bỏ qua."
fi

# --- 6. Gỡ cài đặt caffeine ---
echo "--> Bước 6: Gỡ cài đặt gói caffeine..."
if dpkg -s caffeine &> /dev/null; then
    sudo apt-get remove -y caffeine
    sudo apt-get autoremove -y # Dọn dẹp các gói phụ thuộc không cần thiết
    echo "Đã gỡ cài đặt caffeine."
else
    echo "Gói caffeine chưa được cài đặt. Bỏ qua."
fi

# --- 7. Tùy chọn: Gỡ cài đặt Docker ---
echo "--> Bước 7: Tùy chọn gỡ cài đặt Docker..."
read -p "Bạn có muốn gỡ cài đặt HOÀN TOÀN Docker không? (Lưu ý: Việc này sẽ ảnh hưởng đến các ứng dụng Docker khác nếu có) (y/N): " REMOVE_DOCKER
if [[ "$REMOVE_DOCKER" =~ ^[Yy]$ ]]; then
    echo "Đang dừng các dịch vụ Docker..."
    sudo systemctl stop docker.service
    sudo systemctl stop docker.socket
    sudo systemctl stop containerd.service
    echo "Đang gỡ cài đặt các gói Docker..."
    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
    sudo apt-get autoremove -y --purge
    echo "Đang xóa các thư mục dữ liệu Docker (CẢNH BÁO: Mất dữ liệu Docker)..."
    sudo rm -rf /var/lib/docker
    sudo rm -rf /var/lib/containerd
    sudo rm -rf /etc/docker
    echo "Đã gỡ cài đặt hoàn toàn Docker."
else
    echo "Bỏ qua việc gỡ cài đặt Docker."
    echo "Để vô hiệu hóa Docker khởi động cùng hệ thống, chạy: sudo systemctl disable docker.service docker.socket containerd.service"
fi

echo "====================================================="
echo "           QUÁ TRÌNH GỠ BỎ HOÀN TẤT"
echo "====================================================="
echo "Kiểm tra lại hệ thống để đảm bảo mọi thứ đã được dọn dẹp."
echo "Bạn có thể cần khởi động lại máy nếu gặp vấn đề."
