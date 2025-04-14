#!/bin/bash

echo "==== BẮT ĐẦU QUÁ TRÌNH HỦY BỎ CÀI ĐẶT N8N VÀ CLOUDFLARE TUNNEL ===="
echo "CẢNH BÁO: Script này sẽ dừng và xóa các container Docker liên quan,"
echo "xóa các tệp cấu hình và dữ liệu (bao gồm cả dữ liệu n8n và postgresql),"
echo "và cố gắng gỡ bỏ các thiết lập hệ thống như cron job."
echo ""
read -p "Bạn có chắc chắn muốn tiếp tục? (y/N): " CONFIRM_DELETE

if [[ ! "$CONFIRM_DELETE" =~ ^[Yy]$ ]]; then
    echo "Đã hủy bỏ."
    exit 0
fi

# --- Xác định các biến cần thiết (Dựa trên giá trị mặc định trong script gốc) ---
# Nếu bạn đã thay đổi các đường dẫn này trong script gốc, hãy cập nhật chúng ở đây.
BASE_DIR="docker-run"
MONITOR_SCRIPT_NAME="monitor_vps.sh"
MONITOR_SCRIPT_PATH="$HOME/$MONITOR_SCRIPT_NAME" # Script gốc lưu trong $HOME
MONITOR_LOG_PATH="$HOME/vps_monitor.log"

echo "Sẽ sử dụng các đường dẫn mặc định sau để dọn dẹp:"
echo "  - Thư mục cài đặt Docker: $PWD/$BASE_DIR"
echo "  - Script monitor (nếu có): $MONITOR_SCRIPT_PATH"
echo "  - Log monitor (nếu có): $MONITOR_LOG_PATH"
read -p "Nếu các đường dẫn trên không đúng, hãy nhấn Ctrl+C để hủy và sửa lại script. Nhấn Enter để tiếp tục."

# --- 1. Dừng và xóa các container Docker ---
echo "==== Đang dừng và xóa các container Docker (n8n, postgres, cloudflared)... ===="
if [ -d "$BASE_DIR" ] && [ -f "$BASE_DIR/docker-compose.yml" ]; then
    echo "Tìm thấy thư mục '$BASE_DIR' và file 'docker-compose.yml'. Đang thực hiện docker compose down..."
    cd "$BASE_DIR" || { echo "Lỗi: Không thể chuyển vào thư mục $BASE_DIR"; exit 1; }

    # --volumes sẽ xóa cả các volume được Docker quản lý (n8n_data, postgres_data)
    # --remove-orphans xóa các container không còn được định nghĩa nhưng vẫn thuộc project
    sudo docker compose down --volumes --remove-orphans
    if [ $? -ne 0 ]; then
        echo "Cảnh báo: Có lỗi xảy ra khi chạy 'docker compose down'. Vui lòng kiểm tra thủ công."
    else
        echo "Đã dừng và xóa các container, volumes liên quan."
    fi
    cd .. # Quay lại thư mục gốc
else
    echo "Không tìm thấy thư mục '$BASE_DIR' hoặc file 'docker-compose.yml'. Bỏ qua bước dừng container."
    echo "Nếu bạn cài đặt ở vị trí khác, bạn cần dừng và xóa chúng thủ công:"
    echo "  cd /đường/dẫn/của/bạn/$BASE_DIR"
    echo "  sudo docker compose down --volumes --remove-orphans"
fi

# --- 2. Xóa các tệp và thư mục đã tạo ---
echo "==== Đang xóa thư mục cài đặt và cấu hình ($BASE_DIR)... ===="
if [ -d "$BASE_DIR" ]; then
    sudo rm -rf "$BASE_DIR"
    if [ $? -ne 0 ]; then
        echo "Lỗi: Không thể xóa thư mục '$BASE_DIR'. Vui lòng xóa thủ công: sudo rm -rf $BASE_DIR"
    else
        echo "Đã xóa thư mục '$BASE_DIR'."
    fi
else
    echo "Không tìm thấy thư mục '$BASE_DIR'. Bỏ qua."
fi

# --- 3. Hoàn tác thiết lập script monitor (nếu có) ---
echo "==== Đang kiểm tra và gỡ bỏ script monitor (nếu đã cài đặt)... ===="
# Hỏi người dùng xem họ có cài đặt script monitor không
read -p "Bạn có đã chọn cài đặt script giữ session (monitor_vps.sh) không? (y/N): " DID_SETUP_MONITOR

if [[ "$DID_SETUP_MONITOR" =~ ^[Yy]$ ]]; then
    echo "Đang gỡ bỏ cron job cho $MONITOR_SCRIPT_PATH..."
    # Lấy crontab hiện tại, lọc bỏ dòng chứa script, rồi ghi lại crontab
    (crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT_PATH") | crontab -
    if [ $? -ne 0 ]; then
         echo "Cảnh báo: Có thể đã xảy ra lỗi khi tự động gỡ bỏ cron job. Vui lòng kiểm tra thủ công ('crontab -e')."
    else
         echo "Đã cố gắng gỡ bỏ cron job."
    fi

    echo "Đang xóa file script $MONITOR_SCRIPT_PATH..."
    if [ -f "$MONITOR_SCRIPT_PATH" ]; then
        rm -f "$MONITOR_SCRIPT_PATH"
        echo "Đã xóa $MONITOR_SCRIPT_PATH."
    else
        echo "Không tìm thấy file $MONITOR_SCRIPT_PATH. Bỏ qua."
    fi

    echo "Đang xóa file log $MONITOR_LOG_PATH..."
     if [ -f "$MONITOR_LOG_PATH" ]; then
        rm -f "$MONITOR_LOG_PATH"
        echo "Đã xóa $MONITOR_LOG_PATH."
    else
        echo "Không tìm thấy file $MONITOR_LOG_PATH. Bỏ qua."
    fi

    # Tùy chọn: Gỡ cài đặt curl nếu bạn chắc chắn không cần nó nữa
    # read -p "Bạn có muốn gỡ cài đặt 'curl' không? (y/N): " UNINSTALL_CURL
    # if [[ "$UNINSTALL_CURL" =~ ^[Yy]$ ]]; then
    #     echo "Đang gỡ cài đặt curl..."
    #     sudo apt remove -y curl
    #     sudo apt autoremove -y # Dọn dẹp các gói phụ thuộc không cần thiết
    # fi
else
    echo "Bỏ qua việc gỡ bỏ script monitor."
fi

# --- 4. Hoàn tác thay đổi hệ thống (Docker service) ---
# Script gốc chỉ unmask và start/enable Docker, không cài đặt Docker engine.
# Chúng ta sẽ dừng và disable nó, nhưng không gỡ cài đặt Docker engine hoàn toàn
# trừ khi người dùng muốn. Gỡ docker-compose vì script gốc đã cài nó.
echo "==== Đang dừng và vô hiệu hóa các dịch vụ Docker... ===="
sudo systemctl stop docker docker.socket containerd.service || echo "Cảnh báo: Không thể dừng một hoặc nhiều dịch vụ Docker (có thể chúng đã dừng)."
sudo systemctl disable docker || echo "Cảnh báo: Không thể vô hiệu hóa dịch vụ Docker."
# Việc mask lại thường không cần thiết, chỉ cần disable là đủ.
# sudo systemctl mask docker docker.socket containerd.service

echo "==== Đang gỡ cài đặt docker-compose... ===="
sudo apt remove -y docker-compose
sudo apt autoremove -y # Dọn dẹp các gói phụ thuộc không cần thiết
echo "Đã gỡ cài đặt docker-compose."

# --- 5. Nhắc nhở về các bước thủ công trên Cloudflare ---
echo "==== QUAN TRỌNG: HÀNH ĐỘNG THỦ CÔNG TRÊN CLOUDFLARE ===="
echo "Script đã dọn dẹp các thành phần trên máy chủ này. Bạn cần thực hiện các bước sau trên trang quản trị Cloudflare:"
echo "  1. Xóa bản ghi CNAME:"
echo "     - Truy cập vào phần DNS của tên miền của bạn."
echo "     - Tìm và xóa bản ghi CNAME có tên trỏ đến Tunnel (ví dụ: bản ghi CNAME cho tên miền phụ bạn đã nhập)."
echo "  2. Xóa Cloudflare Tunnel:"
echo "     - Truy cập Cloudflare Zero Trust Dashboard."
echo "     - Vào mục Access -> Tunnels."
echo "     - Tìm Tunnel bạn đã tạo (dựa trên tên bạn đã nhập khi cài đặt) và xóa nó."
echo "--------------------------------------------------"

echo "==== QUÁ TRÌNH DỌN DẸP TRÊN MÁY CHỦ HOÀN TẤT ===="
echo "Hãy đảm bảo bạn đã thực hiện các bước thủ công trên Cloudflare."
