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
}

# 显示当前规则
show_rules() {
    echo -e "\n\033[1;36m===== 当前端口转发规则 (PREROUTING链) =====\033[0m"
    
    # 获取带行号的规则
    iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | awk '
    BEGIN { count = 0 }
    /^[0-9]/ {
        # 提取规则信息
        rule_line = $0
        interface = ""
        ports = ""
        proto = ""
        to_port = ""
        
        # 获取协议
        if (rule_line ~ /^[0-9]+\s+[a-zA-Z]+\s+[a-zA-Z]+\s+(tcp|udp)/) {
            proto = $5
        }
        
        # 获取源端口
        if (rule_line ~ /dpts?:[0-9:]+/) {
            match(rule_line, /dpts?:([0-9:-]+)/, ports)
            ports = ports[1]
        } else if (rule_line ~ /dpt:[0-9]+/) {
            match(rule_line, /dpt:([0-9]+)/, ports)
            ports = ports[1]
        }
        
        # 获取目标端口
        if (rule_line ~ /to:[0-9]+/) {
            match(rule_line, /to:([0-9]+)/, to_port)
            to_port = to_port[1]
        }
        
        # 获取接口
        if (rule_line ~ /IN=[a-zA-Z0-9]+/) {
            match(rule_line, /IN=([a-zA-Z0-9]+)/, iface)
            interface = iface[1]
        } else {
            interface = "all"
        }
        
        if (ports != "" && to_port != "") {
            printf "%-3s | %-5s | %-8s | %-15s => %-5s\n", $1, proto, interface, ports, to_port
            count++
        }
    }
    END { 
        if (count == 0) print "没有端口转发规则"
    }'
    
    echo -e "\033[1;36m===============================================\033[0m"
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

# 获取网络接口列表
get_interfaces() {
    interfaces=()
    while read -r line; do
        if [[ $line =~ ^[0-9]+:\ [a-zA-Z0-9]+: ]]; then
            interface=$(echo $line | awk -F': ' '{print $2}' | sed 's/://')
            interfaces+=("$interface")
        fi
    done < <(ip link show)
    
    echo "${interfaces[@]}"
}

# 添加新规则
add_rule() {
    echo -e "\n\033[1;32m===== 添加新端口转发规则 =====\033[0m"
    
    # 获取网络接口
    interfaces=($(get_interfaces))
    
    # 选择协议
    echo "选择协议:"
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
        read -p "输入源端口或端口范围 (如 80 或 1000-2000): " src_port
        if [[ $src_port =~ ^[0-9]{1,5}([-:][0-9]{1,5})?$ ]]; then
            # 替换任何分隔符为标准的:
            src_port=$(echo "$src_port" | tr '-' ':')
            break
        fi
        echo "无效格式! 请使用单端口(80)或范围(1000:2000)"
    done
    
    # 输入目标端口
    while true; do
        read -p "输入目标端口 (1-65535): " dst_port
        if [[ $dst_port =~ ^[1-9][0-9]{0,4}$ ]] && [ $dst_port -le 65535 ]; then
            break
        fi
        echo "无效端口号! 必须是1-65535"
    done
    
    # 应用规则
    for p in $protocol; do
        if [[ $src_port == *:* ]]; then
            # 端口范围处理
            if [ -z "$interface" ]; then
                iptables -t nat -A PREROUTING -p $p -m multiport --dports "$src_port" -j REDIRECT --to-port "$dst_port"
            else
                iptables -t nat -A PREROUTING -i $interface -p $p -m multiport --dports "$src_port" -j REDIRECT --to-port "$dst_port"
            fi
            echo "已添加: $p $interface [$src_port] -> $dst_port"
        else
            # 单端口处理
            if [ -z "$interface" ]; then
                iptables -t nat -A PREROUTING -p $p --dport "$src_port" -j REDIRECT --to-port "$dst_port"
            else
                iptables -t nat -A PREROUTING -i $interface -p $p --dport "$src_port" -j REDIRECT --to-port "$dst_port"
            fi
            echo "已添加: $p $interface $src_port -> $dst_port"
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
        echo "4) 保存规则到持久存储"
        echo "5) 退出脚本"
        echo "==================================="
        
        read -p "请选择操作 (1-5): " choice
        
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) show_rules ;;
            4) save_rules ;;
            5) 
                echo "退出脚本"
                exit 0 
                ;;
            *) 
                echo -e "\033[1;31m无效选择! 请输入1-5的数字\033[0m"
                ;;
        esac
    done
}

# 初始化脚本
clear
echo -e "\033[1;35m===== IPTABLES 端口转发脚本 =====\033[0m"
echo -e "\033[1;33m正在检查系统依赖...\033[0m"
install_deps
main_menu
