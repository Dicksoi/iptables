#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
    echo "错误：必须使用root权限运行此脚本！" 1>&2
    exit 1
fi

# 安装依赖
install_deps() {
    # 检测系统类型
    if [ -f /etc/debian_version ]; then
        if ! command -v iptables >/dev/null; then
            echo "安装iptables..."
            apt-get update && apt-get install -y iptables
        fi
        
        if ! command -v netfilter-persistent >/dev/null; then
            echo "安装iptables-persistent..."
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y iptables-persistent
        fi
        
    elif [ -f /etc/redhat-release ]; then
        if ! command -v iptables >/dev/null; then
            echo "安装iptables..."
            yum install -y iptables
        fi
        
        if ! systemctl status iptables >/dev/null 2>&1; then
            echo "安装iptables-services..."
            yum install -y iptables-services
            systemctl enable iptables
            systemctl start iptables
        fi
    else
        echo "警告：未知的系统类型，持久化可能无法正常工作"
    fi
    
    # 确保ip命令可用
    if ! command -v ip >/dev/null; then
        echo "安装iproute2工具..."
        if [ -f /etc/debian_version ]; then
            apt-get install -y iproute2
        else
            yum install -y iproute
        fi
    fi
}

# 获取网络接口和IP地址信息
get_interfaces() {
    interfaces=()
    while IFS= read -r line; do
        if [[ $line =~ ^[0-9]+:\ ([^:]+): ]]; then
            interface="${BASH_REMATCH[1]}"
            interfaces+=("$interface")
        fi
    done < <(ip -o link show)
}

# 显示网络接口及其IP地址
show_interface_info() {
    local interfaces=($@)
    local longest_ifname=0
    
    # 找出最长的接口名用于对齐
    for iface in "${interfaces[@]}"; do
        if [ ${#iface} -gt $longest_ifname ]; then
            longest_ifname=${#iface}
        fi
    done
    
    # 显示表头
    printf "%-${longest_ifname}s | %-15s | %s\n" "接口名称" "IP地址" "网络类型"
    printf "%-${longest_ifname}s-+-%15s-+-%s\n" $(printf '%0.s-' $(seq 1 $longest_ifname)) \
        $(printf '%0.s-' $(seq 1 15)) \
        "---------------"
    
    # 显示每个接口的信息
    for iface in "${interfaces[@]}"; do
        # 获取接口IP地址
        ip_info=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}')
        
        # 如果没有IPv4地址，尝试获取IPv6地址
        if [ -z "$ip_info" ]; then
            ip_info=$(ip -o -6 addr show dev "$iface" 2>/dev/null | head -1 | awk '{print $4}')
        fi
        
        # 检测网络类型
        net_type="本地"
        if [[ $iface == en* || $iface == eth* ]]; then
            net_type="有线"
        elif [[ $iface == wl* || $iface == wlan* ]]; then
            net_type="无线"
        fi
        
        # 显示接口信息
        if [ -n "$ip_info" ]; then
            printf "%-${longest_ifname}s | %-15s | %s\n" "$iface" "$ip_info" "$net_type"
        else
            printf "%-${longest_ifname}s | %-15s | %s\n" "$iface" "无IP地址" "$net_type"
        fi
    done
    
    echo -e "\033[1;33m提示：如果多个接口有相同IP，请检查网络配置\033[0m"
}

# 显示当前规则 - 详细格式
show_rules() {
    echo -e "\n\033[1;36m===== 当前端口转发规则 (PREROUTING链) =====\033[0m"
    
    # 获取带行号的详细规则
    iptables -t nat -L PREROUTING -n -v --line-numbers
    
    echo -e "\033[1;36m====================================================\033[0m"
}

# 保存规则到持久存储
save_rules() {
    echo -e "\n\033[1;33m正在保存规则...\033[0m"
    
    if [ -f /etc/debian_version ]; then
        # Debian/Ubuntu 系统
        if command -v netfilter-persistent >/dev/null; then
            netfilter-persistent save >/dev/null
            echo "已使用 netfilter-persistent 保存规则"
        else
            iptables-save > /etc/iptables/rules.v4
            echo "规则已保存到 /etc/iptables/rules.v4"
        fi
        
    elif [ -f /etc/redhat-release ]; then
        # CentOS/RHEL 系统
        if command -v service >/dev/null; then
            service iptables save >/dev/null
            echo "已使用 service iptables save 保存规则"
        else
            iptables-save > /etc/sysconfig/iptables
            echo "规则已保存到 /etc/sysconfig/iptables"
        fi
    else
        # 其他系统尝试保存
        iptables-save > /etc/iptables.conf
        echo "规则已保存到 /etc/iptables.conf"
        echo "注意：需要手动配置启动时加载规则"
    fi
    
    echo -e "\033[1;32m规则已持久化保存，重启后自动加载\033[0m"
}

# 验证端口格式
validate_port() {
    local port=$1
    local is_range=$2
    
    # 验证单端口
    if [[ $is_range == "single" ]]; then
        if [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && [ $port -le 65535 ]; then
            return 0
        fi
        return 1
    fi
    
    # 验证端口范围
    if [[ $port =~ ^([0-9]{1,5})[:]([0-9]{1,5})$ ]]; then
        local start_port=${BASH_REMATCH[1]}
        local end_port=${BASH_REMATCH[2]}
        
        if [ $start_port -le 65535 ] && [ $end_port -le 65535 ] && [ $start_port -lt $end_port ]; then
            return 0
        fi
    fi
    
    return 1
}

# 添加新规则
add_rule() {
    echo -e "\n\033[1;32m===== 添加新端口转发规则 =====\033[0m"
    
    # 获取网络接口
    interfaces=()
    get_interfaces
    
    # 显示接口和IP信息
    echo -e "\n\033[1;34m可用网络接口和IP地址：\033[0m"
    show_interface_info "${interfaces[@]}"
    
    # 选择协议
    echo -e "\n选择协议:"
    echo "1) TCP"
    echo "2) UDP"
    echo "3) TCP和UDP"
    read -p "输入选择 (1-3): " proto_choice
    
    case $proto_choice in
        1) protocol="tcp" ;;
        2) protocol="udp" ;;
        3) protocol="tcp udp" ;;
        *) 
            echo "无效选择，默认使用TCP"
            protocol="tcp" 
            ;;
    esac
    
    # 选择网络接口
    echo -e "\n选择网络接口:"
    select interface in "${interfaces[@]}" "所有接口"; do
        if [ -n "$interface" ]; then
            if [ "$interface" = "所有接口" ]; then
                interface=""
            fi
            break
        fi
        echo "无效选择，请重试!"
    done
    
    # 输入源端口（支持范围）
    while true; do
        read -p "输入源端口或端口范围 (如 80 或 38901:38999): " src_port
        
        # 替换任何分隔符为标准的冒号
        src_port=$(echo "$src_port" | tr '-' ':')
        
        # 判断是单端口还是范围
        if [[ $src_port == *:* ]]; then
            if validate_port "$src_port" "range"; then
                break
            else
                echo "错误：无效的端口范围格式！请使用 起始端口:结束端口 如 38901:38999"
            fi
        else
            if validate_port "$src_port" "single"; then
                break
            else
                echo "错误：无效的端口号！端口必须在1-65535范围内"
            fi
        fi
    done
    
    # 输入目标端口
    while true; do
        read -p "输入目标端口 (1-65535): " dst_port
        if validate_port "$dst_port" "single"; then
            break
        else
            echo "错误：无效的端口号！目标端口必须在1-65535范围内"
        fi
    done
    
    # 确认信息
    echo -e "\n\033[1;35m即将添加以下规则：\033[0m"
    if [ -z "$interface" ]; then
        echo "所有接口 | $protocol | $src_port -> $dst_port"
    else
        # 再次显示选择的接口IP
        interface_ip=$(ip -o -4 addr show dev "$interface" 2>/dev/null | awk '{print $4}')
        if [ -z "$interface_ip" ]; then
            interface_ip=$(ip -o -6 addr show dev "$interface" 2>/dev/null | head -1 | awk '{print $4}')
        fi
        if [ -z "$interface_ip" ]; then
            interface_ip="无IP地址"
        fi
        
        echo "接口: $interface ($interface_ip) | $protocol | $src_port -> $dst_port"
    fi
    
    read -p "是否确认添加? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[yY] ]]; then
        echo "已取消添加规则"
        return
    fi
    
    # 应用规则
    for p in $protocol; do
        if [[ $src_port == *:* ]]; then
            # 端口范围处理
            if [ -z "$interface" ]; then
                iptables -t nat -A PREROUTING -p $p -m multiport --dports "$src_port" -j REDIRECT --to-port "$dst_port"
            else
                iptables -t nat -A PREROUTING -i $interface -p $p -m multiport --dports "$src_port" -j REDIRECT --to-port "$dst_port"
            fi
            echo -e "\033[1;32m已添加: $p $interface [$src_port] -> $dst_port\033[0m"
        else
            # 单端口处理
            if [ -z "$interface" ]; then
                iptables -t nat -A PREROUTING -p $p --dport "$src_port" -j REDIRECT --to-port "$dst_port"
            else
                iptables -t nat -A PREROUTING -i $interface -p $p --dport "$src_port" -j REDIRECT --to-port "$dst_port"
            fi
            echo -e "\033[1;32m已添加: $p $interface $src_port -> $dst_port\033[0m"
        fi
    done
    
    save_rules
}

# 删除现有规则
delete_rule() {
    while true; do
        show_rules
        
        # 获取规则数量
        rule_count=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -c '^[0-9]')
        if [ "$rule_count" -eq 0 ]; then
            read -p "没有可删除的规则，按回车返回主菜单"
            return
        fi
        
        echo -e "\n输入要删除的规则编号 (输入0返回主菜单): "
        read -p "> " rule_num
        
        if [ "$rule_num" = "0" ]; then
            return
        fi
        
        if [[ "$rule_num" =~ ^[0-9]+$ ]] && [ "$rule_num" -le "$rule_count" ] && [ "$rule_num" -gt 0 ]; then
            # 先显示规则详细信息
            rule_info=$(iptables -t nat -L PREROUTING -n -v --line-numbers | awk -v num=$rule_num '$1 == num {print $0}')
            echo -e "\033[1;31m将要删除的规则：\033[0m"
            echo "$rule_info"
            
            # 确认删除
            read -p "确认删除这条规则? [y/N] " confirm
            if [[ ! "$confirm" =~ ^[yY] ]]; then
                echo "已取消删除"
                continue
            fi
            
            # 删除规则
            iptables -t nat -D PREROUTING "$rule_num"
            
            if [ $? -eq 0 ]; then
                echo -e "\033[1;32m规则 $rule_num 已成功删除\033[0m"
                save_rules
            else
                echo -e "\033[1;31m删除失败! 请检查行号\033[0m"
            fi
        else
            echo -e "\033[1;31m无效的规则编号! 有效范围: 1-$rule_count\033[0m"
        fi
    done
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n\033[1;34m===== IPTABLES 端口转发管理 =====\033[0m"
        echo "1) 添加新的端口转发规则"
        echo "2) 删除现有的端口转发规则"
        echo "3) 显示当前所有规则"
        echo "4) 显示网络接口信息"
        echo "5) 保存规则到持久存储"
        echo "6) 退出脚本"
        echo "==================================="
        
        read -p "请选择操作 (1-6): " choice
        
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) show_rules ;;
            4) 
                clear
                interfaces=()
                get_interfaces
                show_interface_info "${interfaces[@]}"
                ;;
            5) save_rules ;;
            6) 
                echo "退出脚本"
                exit 0 
                ;;
            *) 
                echo -e "\033[1;31m无效选择! 请输入1-6的数字\033[0m"
                ;;
        esac
    done
}

# 初始化脚本
clear
echo -e "\033[1;35m===== IPTABLES 端口转发脚本 =====\033[0m"
echo -e "\033[1;33m正在检查系统依赖...\033[0m"
install_deps
interfaces=()
get_interfaces
main_menu
