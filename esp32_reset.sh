#!/bin/bash

###########################################
# Cấu hình
###########################################
# Danh sách các cổng USB cần kiểm tra
USB_PORTS=("/dev/ttyUSB0" "/dev/ttyUSB1" "/dev/ttyUSB2" "/dev/ttyUSB3" "/dev/ttyUSB4" "/dev/ttyUSB5" "/dev/ttyUSB6")
# Tốc độ Baud cho kết nối Serial
BAUD_RATES=(9600 115200)  # Thử nhiều tốc độ baud khác nhau
# Đường dẫn file log
LOG_FILE="/var/log/esp32_reset.log"
# Số lần thử lại tối đa cho mỗi thao tác
MAX_RETRIES=3
# Thời gian chờ giữa các lần thử (giây)
RETRY_DELAY=2
# Thời gian chờ để screen khởi động (giây)
SCREEN_WAIT_TIME=2
# Đường dẫn đến screen binary
SCREEN_CMD="/usr/bin/screen"
# Kích thước tối đa của file log (bytes)
MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB
# Email để nhận thông báo (để trống nếu không muốn nhận mail)
ADMIN_EMAIL=""

###########################################
# Định nghĩa màu sắc
###########################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

###########################################
# Hàm utility
###########################################
# Hàm ghi log
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="${timestamp} - [${level}] ${message}"
    
    # Kiểm tra kích thước file log
    if [ -f "$LOG_FILE" ]; then
        local current_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
        if [ "$current_size" -gt "$MAX_LOG_SIZE" ]; then
            # Rotate log file
            mv "$LOG_FILE" "${LOG_FILE}.old"
            touch "$LOG_FILE"
            log_message "INFO" "Log file đã được rotate do vượt quá kích thước cho phép"
        fi
    fi
    
    echo -e "${log_entry}" >> "$LOG_FILE"
    
    # Hiển thị ra terminal nếu chạy thủ công
    if [ -t 1 ]; then
        case $level in
            "ERROR") echo -e "${RED}${log_entry}${NC}" ;;
            "WARNING") echo -e "${YELLOW}${log_entry}${NC}" ;;
            "INFO") echo -e "${GREEN}${log_entry}${NC}" ;;
            "DEBUG") echo -e "${BLUE}${log_entry}${NC}" ;;
        esac
    fi
    
    # Gửi email nếu có lỗi và đã cấu hình email
    if [ "$level" == "ERROR" ] && [ -n "$ADMIN_EMAIL" ]; then
        echo "$log_entry" | mail -s "ESP32 Reset Script Error" "$ADMIN_EMAIL"
    fi
}

# Hàm kiểm tra và cài đặt các dependencies
check_dependencies() {
    local required_deps=("screen" "lsof")
    local optional_deps=("mailutils")  # mail command comes from mailutils
    local missing_deps=()
    
    # Kiểm tra required dependencies
    for dep in "${required_deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    # Kiểm tra mail command chỉ khi ADMIN_EMAIL được cấu hình
    if [ -n "$ADMIN_EMAIL" ]; then
        if ! command -v mail &> /dev/null; then
            missing_deps+=("mailutils")
        fi
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_message "WARNING" "Đang cài đặt các dependencies còn thiếu: ${missing_deps[*]}"
        if ! sudo apt-get update &> /dev/null; then
            log_message "ERROR" "Không thể cập nhật package list"
            exit 1
        fi
        
        for dep in "${missing_deps[@]}"; do
            if ! sudo apt-get install -y "$dep"; then
                log_message "ERROR" "Không thể cài đặt $dep"
                exit 1
            fi
        done
        
        # Đợi và kiểm tra lại
        sleep 2
        hash -r
        source /etc/profile &> /dev/null || true
        
        # Kiểm tra lại các required dependencies
        for dep in "${required_deps[@]}"; do
            if ! command -v "$dep" &> /dev/null; then
                log_message "ERROR" "Không thể tìm thấy $dep sau khi cài đặt"
                exit 1
            fi
        done
        
        # Kiểm tra lại mail command nếu cần
        if [ -n "$ADMIN_EMAIL" ]; then
            if ! command -v mail &> /dev/null; then
                log_message "WARNING" "Không thể tìm thấy lệnh mail. Tính năng thông báo qua email sẽ bị vô hiệu hóa."
            fi
        fi
        
        log_message "INFO" "Đã cài đặt tất cả dependencies bắt buộc thành công"
    fi
}

# Hàm kiểm tra quyền sudo
check_sudo() {
    if [ "$EUID" -ne 0 ]; then
        log_message "ERROR" "Script cần được chạy với quyền root (sudo)"
        exit 1
    fi
}

# Hàm kiểm tra và tạo thiết lập ban đầu
initialize() {
    # Tạo thư mục log nếu chưa tồn tại
    local log_dir=$(dirname "$LOG_FILE")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
    fi
    
    # Thiết lập quyền cho file log
    touch "$LOG_FILE"
    chmod 666 "$LOG_FILE"
    
    # Kiểm tra quyền ghi
    if ! touch "$LOG_FILE" 2>/dev/null; then
        echo "Không thể ghi vào file log $LOG_FILE"
        exit 1
    fi
}

# Hàm kiểm tra xem port có đang được sử dụng không
check_port_in_use() {
    local port=$1
    if lsof "$port" &> /dev/null; then
        return 0  # Port đang được sử dụng
    fi
    return 1  # Port không được sử dụng
}

# Hàm giải phóng port
free_port() {
    local port=$1
    local retries=0
    
    while [ $retries -lt $MAX_RETRIES ]; do
        if check_port_in_use "$port"; then
            log_message "WARNING" "Port $port đang bị chiếm dụng, đang giải phóng..."
            fuser -k "$port" 2>/dev/null
            sleep 1
            if ! check_port_in_use "$port"; then
                log_message "INFO" "Đã giải phóng port $port thành công"
                return 0
            fi
        else
            return 0
        fi
        ((retries++))
        sleep "$RETRY_DELAY"
    done
    
    log_message "ERROR" "Không thể giải phóng port $port sau $MAX_RETRIES lần thử"
    return 1
}

# Hàm xử lý một cổng USB với một baudrate cụ thể
handle_port_with_baudrate() {
    local port=$1
    local baudrate=$2
    local retry_count=0
    
    log_message "DEBUG" "Thử kết nối với port $port ở baudrate $baudrate"
    
    while [ $retry_count -lt $MAX_RETRIES ]; do
        # Kiểm tra và giải phóng port nếu cần
        if ! free_port "$port"; then
            return 1
        fi
        
        # Tạo screen session mới
        if ! $SCREEN_CMD "$port" "$baudrate" &> /dev/null; then
            log_message "WARNING" "Không thể tạo screen session cho ${port} với baudrate ${baudrate} (lần thử ${retry_count})"
            ((retry_count++))
            sleep "$RETRY_DELAY"
            continue
        fi
        
        # Đợi screen khởi động
        sleep "$SCREEN_WAIT_TIME"
        
        # Tìm và đóng screen session
        local screen_list
        screen_list=$($SCREEN_CMD -ls 2>/dev/null)
        if [ $? -eq 0 ]; then
            while IFS= read -r line; do
                if [[ $line =~ ^[[:space:]]*([0-9]+)\. ]]; then
                    local pid="${BASH_REMATCH[1]}"
                    if $SCREEN_CMD -S "$pid" -X quit &> /dev/null; then
                        log_message "INFO" "Reset thành công port $port với baudrate $baudrate"
                        return 0
                    fi
                fi
            done <<< "$screen_list"
        fi
        
        ((retry_count++))
        sleep "$RETRY_DELAY"
    done
    
    log_message "ERROR" "Không thể xử lý port $port với baudrate $baudrate sau $MAX_RETRIES lần thử"
    return 1
}

# Hàm xử lý một cổng USB
handle_port() {
    local port=$1
    local success=false
    
    for baudrate in "${BAUD_RATES[@]}"; do
        if handle_port_with_baudrate "$port" "$baudrate"; then
            success=true
            break
        fi
    done
    
    if [ "$success" = true ]; then
        return 0
    else
        return 1
    fi
}

# Hàm dọn dẹp
cleanup() {
    log_message "INFO" "Đang dọn dẹp..."
    
    # Tìm và đóng tất cả các screen sessions
    if [ -x "$SCREEN_CMD" ]; then
        local screen_list
        screen_list=$($SCREEN_CMD -ls 2>/dev/null)
        if [ $? -eq 0 ]; then
            while IFS= read -r line; do
                if [[ $line =~ ^[[:space:]]*([0-9]+)\. ]]; then
                    local pid="${BASH_REMATCH[1]}"
                    $SCREEN_CMD -S "$pid" -X quit &> /dev/null
                fi
            done <<< "$screen_list"
        fi
    fi
    
    # Giải phóng tất cả các port đang được định nghĩa
    for port in "${USB_PORTS[@]}"; do
        if [ -e "$port" ]; then
            free_port "$port" || true
        fi
    done
}

# Hàm kiểm tra và thêm cron job
setup_cron() {
    local script_path=$(readlink -f "$0")
    local cron_schedule="0 0 * * *"  # Chạy lúc 12h đêm mỗi ngày
    local cron_cmd="$script_path"
    local cron_job="$cron_schedule $cron_cmd"

    # Kiểm tra xem cron job đã tồn tại chưa
    if ! sudo crontab -l 2>/dev/null | grep -Fq "$cron_cmd"; then
        log_message "INFO" "Đang thêm script vào crontab để chạy lúc 12h đêm hàng ngày..."
        
        # Lưu crontab hiện tại
        local temp_cron=$(mktemp)
        sudo crontab -l 2>/dev/null > "$temp_cron"
        
        # Thêm cronjob mới
        echo "$cron_job" >> "$temp_cron"
        
        # Cập nhật crontab
        if sudo crontab "$temp_cron"; then
            log_message "INFO" "Đã thêm script vào crontab thành công"
        else
            log_message "ERROR" "Không thể thêm script vào crontab"
        fi
        
        # Xóa file tạm
        rm -f "$temp_cron"
    else
        log_message "INFO" "Script đã được cấu hình trong crontab"
    fi
}

# Hàm kiểm tra và cấp quyền cho USB port
setup_usb_permissions() {
    # Kiểm tra xem user có trong nhóm dialout không
    local current_user=$(who am i | awk '{print $1}')
    if ! groups $current_user | grep -q "dialout"; then
        log_message "WARNING" "User $current_user chưa có quyền truy cập USB port"
        log_message "INFO" "Đang thêm user vào nhóm dialout..."
        if sudo usermod -a -G dialout $current_user; then
            log_message "INFO" "Đã thêm user vào nhóm dialout thành công"
            log_message "WARNING" "Vui lòng đăng xuất và đăng nhập lại để áp dụng thay đổi"
        else
            log_message "ERROR" "Không thể thêm user vào nhóm dialout"
        fi
    fi

    # Cấp quyền cho các USB port
    for port in "${USB_PORTS[@]}"; do
        if [ -e "$port" ]; then
            log_message "DEBUG" "Đang cấp quyền cho port $port"
            if ! sudo chmod 666 "$port"; then
                log_message "ERROR" "Không thể cấp quyền cho port $port"
            fi
        fi
    done
}

###########################################
# Hàm main
###########################################
main() {
    # Đăng ký cleanup khi script kết thúc
    trap cleanup EXIT
    
    # Khởi tạo
    log_message "INFO" "Bắt đầu script reset ESP32"
    
    # Kiểm tra các điều kiện tiên quyết
    check_sudo
    initialize
    check_dependencies
    
    # Thiết lập quyền USB
    setup_usb_permissions
    
    # Thiết lập cron job
    setup_cron
    
    # Xử lý từng cổng USB
    local error_count=0
    local port_found=false
    
    for port in "${USB_PORTS[@]}"; do
        if [ -e "$port" ]; then
            port_found=true
            if ! handle_port "$port"; then
                ((error_count++))
            fi
        else
            log_message "DEBUG" "Không tìm thấy cổng ${port}"
        fi
    done
    
    # Kiểm tra nếu không tìm thấy port nào
    if [ "$port_found" = false ]; then
        log_message "WARNING" "Không tìm thấy ESP32 nào được kết nối"
    fi
    
    # Tổng kết
    if [ $error_count -eq 0 ]; then
        if [ "$port_found" = true ]; then
            log_message "INFO" "Script hoàn thành thành công"
        else
            log_message "INFO" "Script hoàn thành (không có thiết bị nào được tìm thấy)"
        fi
        exit 0
    else
        log_message "WARNING" "Script hoàn thành với ${error_count} lỗi"
        exit 1
    fi
}

# Chạy script
main
