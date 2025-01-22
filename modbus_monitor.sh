#!/bin/bash

# Kiểm tra sudo
if [ "$EUID" -ne 0 ]; then 
    echo "Script này cần được chạy với quyền sudo"
    exit 1
fi

# Cấu hình
MODBUS_IP="192.168.1.199"  # IP của thiết bị modbus
MODBUS_PORT=502          # Port modbus mặc định
CHECK_INTERVAL=120        # Thời gian giữa các lần check (giây)
MAX_RETRIES=3           # Số lần thử lại trước khi reset
RETRY_DELAY=20           # Thời gian chờ giữa các lần thử (giây)
LOG_FILE="/var/log/modbus_monitor.log"
MAX_LOG_SIZE=$((10*1024*1024))  # 10MB
MAX_LOG_FILES=5         # Số file log tối đa để rotate

# Thư mục cố định cho modbus tool
MODBUS_TOOL_DIR="/opt/modbus_tool"
MODPOLL_PATH="$MODBUS_TOOL_DIR/modpoll/x86_64-linux-gnu/modpoll"

# Tạo và set permission cho file log
setup_log() {
    touch "$LOG_FILE"
    chmod 666 "$LOG_FILE"
    chown root:root "$LOG_FILE"
}

# Kiểm tra và tạo thư mục log nếu chưa có
if [ ! -d "$(dirname "$LOG_FILE")" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
fi
setup_log

# Cài đặt modbus tool nếu chưa có
setup_modbus_tool() {
    if [ ! -x "$MODPOLL_PATH" ]; then
        echo "Modbus tool chưa được cài đặt. Đang cài đặt..."
        
        sudo mkdir -p "$MODBUS_TOOL_DIR"
        cd "$MODBUS_TOOL_DIR" || exit 1
        
        wget https://www.modbusdriver.com/downloads/modpoll.tgz
        tar xzf modpoll.tgz
        
        if [ ! -f "$MODPOLL_PATH" ]; then
            echo "Lỗi: Không tìm thấy modpoll sau khi giải nén"
            exit 1
        fi
        
        chmod +x "$MODPOLL_PATH"
        rm modpoll.tgz
        
        echo "Đã cài đặt modbus tool thành công"
    fi
}

# Hàm ghi log với rotation
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="$timestamp - $message"

    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
        if [ -n "$size" ] && [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            for i in $(seq $((MAX_LOG_FILES-1)) -1 1); do
                if [ -f "${LOG_FILE}.$i" ]; then
                    mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))"
                fi
            done
            mv "$LOG_FILE" "${LOG_FILE}.1"
            touch "$LOG_FILE"
            chmod 666 "$LOG_FILE"
        fi
    fi

    echo "$log_entry" >> "$LOG_FILE"
    echo "$log_entry"
}

# Hàm tạo temp file với quyền truy cập đúng
setup_temp_file() {
    local temp_file="/tmp/modpoll_$.out"
    touch "$temp_file"
    chmod 666 "$temp_file"
    echo "$temp_file"
}

# Hàm kiểm tra modbus với temp file trong /dev/shm và timeout ngắn hơn
check_modbus() {
    if [ ! -x "$MODPOLL_PATH" ]; then
        log_message "ERROR: Không tìm thấy modpoll tại $MODPOLL_PATH"
        return 1
    fi
    
    # Lưu thư mục hiện tại
    local current_pwd=$PWD
    
    # Tạo temp file trong /dev/shm với quyền truy cập đúng
    local temp_file
    temp_file=$(mktemp /dev/shm/modpoll.XXXXXX)
    
    # Đảm bảo cleanup khi function kết thúc
    trap "rm -f $temp_file" RETURN
    
    # Chạy modpoll với timeout ngắn hơn (0.5 giây) để phát hiện mất kết nối nhanh hơn
    cd "$(dirname "$MODPOLL_PATH")" && \
    ./modpoll -m tcp -a 1 -r 1 -c 1 -t 0 -1 -o 0.5 "$MODBUS_IP" > "$temp_file" 2>&1
    local exit_code=$?

    # Trở về thư mục ban đầu
    cd "$current_pwd"

    if [ $exit_code -eq 0 ]; then
        log_message "Modbus poll thành công"
        log_message "Chi tiết: $(cat "$temp_file")"
        return 0
    else
        log_message "Modbus poll thất bại (exit code: $exit_code)"
        log_message "Chi tiết lỗi: $(cat "$temp_file")"
        return 1
    fi
}

# Reset board sử dụng script ESP32
reset_board() {
    log_message "Đang thực hiện reset board..."
    
    # Lấy đường dẫn của script hiện tại (modbus_monitor.sh)
    CURRENT_DIR="$(dirname "$(realpath "$0")")"
    
    if [ ! -f "$CURRENT_DIR/esp32_reset.sh" ]; then
        log_message "ERROR: Không tìm thấy script esp32_reset.sh tại $CURRENT_DIR"
        return 1
    fi
    
    # Thực thi script reset từ thư mục hiện tại
    cd "$CURRENT_DIR" && sudo ./esp32_reset.sh
    local reset_result=$?
    
    if [ $reset_result -eq 0 ]; then
        log_message "Reset board thành công"
    else
        log_message "ERROR: Reset board thất bại với mã lỗi $reset_result"
    fi
    
    sleep 10  # Đợi board khởi động lại
}

# Hàm chính được cải tiến để theo dõi liên tục
main() {
    setup_modbus_tool
    local previous_state="unknown"
    local consecutive_failures=0

    while true; do
        local retry_count=0
        local modbus_ok=false

        # Thử kiểm tra modbus
        while [ $retry_count -lt $MAX_RETRIES ]; do
            if check_modbus; then
                modbus_ok=true
                if [ "$previous_state" = "failed" ]; then
                    log_message "Kết nối Modbus đã được phục hồi"
                fi
                previous_state="success"
                consecutive_failures=0
                break
            fi
            
            ((retry_count++))
            ((consecutive_failures++))
            
            if [ "$previous_state" = "success" ] || [ "$previous_state" = "unknown" ]; then
                log_message "Phát hiện mất kết nối Modbus"
                previous_state="failed"
            fi
            
            log_message "Lần thử $retry_count: Không thể kết nối Modbus (Số lần thất bại liên tiếp: $consecutive_failures)"
            
            if [ $retry_count -lt $MAX_RETRIES ]; then
                sleep $RETRY_DELAY
            fi
        done

        # Nếu không kết nối được và đã thất bại nhiều lần, thực hiện reset
        if [ "$modbus_ok" = false ]; then
            log_message "Phát hiện board bị treo Modbus sau $MAX_RETRIES lần thử"
            reset_board
            log_message "Đã hoàn thành quy trình reset"
            previous_state="unknown"
            consecutive_failures=0
        fi

        # Giảm thời gian kiểm tra để phát hiện mất kết nối nhanh hơn
        sleep 5  # Kiểm tra mỗi 5 giây thay vì 60 giây
    done
}

# Khởi chạy script
main
