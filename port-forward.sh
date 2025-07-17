#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
    echo "错误：必须使用root权限运行此脚本！" 1>&2
    exit 1
fi

# 检查并安装依赖
check_dependencies() {
    if ! command -v iptables >/dev/null; then
        echo "正在安装iptables..."
        apt update && apt install -y iptables
    fi
    
    if ! command -v netfilter-persistent >/dev/null; then
        echo "正在安装iptables-persistent..."
        apt update && apt install -y iptables-persistent
    fi
}

# 显示当前规则
show_rules() {
    echo -e "\n\033[1;36m===== 当前端口转发规则 =====\033[0m"
    iptables -t nat -L PREROUTING -n --line-numbers -v 2>/dev/null | grep -E 'REDIRECT|DNAT'
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "未找到端口转发规则"
    fi
    echo -e "\033[1;36m=============================\033[0m"
}

# 保存规则
save_rules() {
    echo -e "\033[1;33m正在保存规则...\033[0m"
    if command -v netfilter-persistent >/dev/null; then
        netfilter-persistent save
    else
        iptables-save > /etc/iptables/rules.v4
    fi
    echo "规则已保存，重启后自动加载"
}

# 添加规则
add_rule() {
    # 获取网络接口列表
    interfaces=($(ip a | awk -F': ' '/^[0-9]+:/{print $2}'))
    
    echo -e "\n\033[1;32m选择网络接口：\033[0m"
    select interface in "${interfaces[@]}" "所有接口"; do
        [ -n "$interface" ] && break
        echo "无效选择，请重试！"
    done
    
    # 处理协议选择
    echo -e "\n\033[1;32m选择协议：\033[0m"
    PS3="输入选项编号 (1-3): "
    options=("TCP" "UDP" "TCP+UDP")
    select proto in "${options[@]}"; do
        case $REPLY in
            1) protocol="tcp"; break ;;
            2) protocol="udp"; break ;;
            3) protocol="tcp udp"; break ;;
            *) echo "无效选择，请重试！" ;;
        esac
    done

    # 输入端口信息
    while true; do
        read -p "输入源端口号 (1-65535): " src_port
        [[ $src_port =~ ^[1-9][0-9]{0,4}$ ]] && ((src_port >= 1 && src_port <= 65535)) && break
        echo "端口号无效！"
    done

    while true; do
        read -p "输入目标端口号 (1-65535): " dst_port
        [[ $dst_port =~ ^[1-9][0-9]{0,4}$ ]] && ((dst_port >= 1 && dst_port <= 65535)) && break
        echo "端口号无效！"
    done

    # 应用规则
    for p in $protocol; do
        if [ "$interface" = "所有接口" ]; then
            iptables -t nat -A PREROUTING -p $p --dport $src_port -j REDIRECT --to-port $dst_port
        else
            iptables -t nat -A PREROUTING -i $interface -p $p --dport $src_port -j REDIRECT --to-port $dst_port
        fi
    done
    
    echo -e "\033[1;32m规则已添加：\033[0m $interface $protocol $src_port -> $dst_port"
    save_rules
}

# 删除规则
delete_rule() {
    while true; do
        show_rules
        if ! iptables -t nat -L PREROUTING -n --line-numbers | grep -q 'REDIRECT'; then
            read -p "没有可删除的规则，按回车键继续..." 
            return
        fi
        
        echo -e "\n\033[1;31m输入要删除的规则编号 (输入0返回上级): \033[0m"
        read rule_num
        
        if [ "$rule_num" = "0" ]; then
            return
        elif [[ "$rule_num" =~ ^[0-9]+$ ]] && iptables -t nat -L PREROUTING --line-numbers | awk 'NR>2{print $1}' | grep -wq $rule_num; then
            iptables -t nat -D PREROUTING $rule_num
            echo "规则 $rule_num 已删除"
            save_rules
        else
            echo "无效的规则编号！"
        fi
    done
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n\033[1;34m===== iptables 端口转发管理 =====\033[0m"
        echo "1) 添加端口转发规则"
        echo "2) 删除端口转发规则"
        echo "3) 显示当前规则"
        echo "4) 保存规则并退出"
        echo "5) 直接退出"
        echo "==============================="
        
        read -p "请输入操作编号 (1-5): " choice
        
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) show_rules ;;
            4) save_rules; exit 0 ;;
            5) exit 0 ;;
            *) echo "无效输入！" ;;
        esac
    done
}

# 初始化
clear
check_dependencies
echo -e "\033[1;32m所需依赖已安装\033[0m"
main_menu
