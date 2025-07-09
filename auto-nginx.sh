#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行此脚本" >&2
    exit 1
fi

# 获取用户输入的域名
echo "请输入您的主域名（例如：example.com）："
read -r domain

echo "请输入www前缀的域名（例如：www.example.com）："
read -r www_domain

# 存储所有子域名的数组
subdomains=()

echo -e "\n现在您可以添加任意数量的子域名（如 dev.${domain}, api.${domain} 等）"
echo "输入子域名前缀（例如：dev），直接回车结束添加"

while true; do
    read -p "子域名前缀 (留空结束): " prefix
    if [ -z "$prefix" ]; then
        break
    fi
    subdomain="${prefix}.${domain}"
    subdomains+=("$subdomain")
    echo "已添加子域名: ${subdomain}"
done

# 构建完整域名列表（包括主域名和www域名）
all_domains=("$domain" "$www_domain")
for sub in "${subdomains[@]}"; do
    all_domains+=("$sub")
done

# 确认输入
echo -e "\n确认配置信息："
echo "主域名: ${domain}"
echo "www域名: ${www_domain}"
echo "子域名数量: ${#subdomains[@]}"
for sub in "${subdomains[@]}"; do
    echo "- ${sub}"
done
echo

# 默认确认选项函数
confirm_default_yes() {
    local prompt="$1"
    read -p "${prompt} (Y/n): " response
    response="${response:-Y}"  # 默认值为Y
    [[ "$response" =~ ^[Yy]$|^$ ]]
}

# 检查系统类型
if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu系统
    NGINX_AVAILABLE="/etc/nginx/sites-available"
    NGINX_ENABLED="/etc/nginx/sites-enabled"
    PKG_MANAGER="apt"
    PKG_UPDATE="apt update"
    PKG_INSTALL="apt install -y"
elif [ -f /etc/redhat-release ]; then
    # CentOS/RHEL系统
    NGINX_AVAILABLE="/etc/nginx/conf.d"
    NGINX_ENABLED="/etc/nginx/conf.d"
    PKG_MANAGER="yum"
    PKG_UPDATE="yum update -y"
    PKG_INSTALL="yum install -y"
else
    echo "不支持的系统类型，脚本可能无法正常工作" >&2
    if confirm_default_yes "是否继续？"; then
        # 默认使用Debian/Ubuntu的配置
        NGINX_AVAILABLE="/etc/nginx/sites-available"
        NGINX_ENABLED="/etc/nginx/sites-enabled"
        PKG_MANAGER="apt"
        PKG_UPDATE="apt update"
        PKG_INSTALL="apt install -y"
    else
        exit 1
    fi
fi

# 创建必要的目录
if [ ! -d "$NGINX_AVAILABLE" ]; then
    sudo mkdir -p "$NGINX_AVAILABLE"
fi

if [ ! -d "$NGINX_ENABLED" ] && [ "$NGINX_AVAILABLE" != "$NGINX_ENABLED" ]; then
    sudo mkdir -p "$NGINX_ENABLED"
fi

# 删除旧配置文件（如果存在）
config_file="${NGINX_AVAILABLE}/${domain}.conf"
enabled_file="${NGINX_ENABLED}/${domain}.conf"

# 检查并删除sites-enabled目录下可能存在的所有与当前域名相关的配置
echo "正在检查并清理旧的Nginx配置文件..."
if [ -d "$NGINX_ENABLED" ]; then
    # 查找并删除可能与当前域名相关的所有配置文件
    for old_conf in "${NGINX_ENABLED}"/*${domain}*; do
        if [ -f "$old_conf" ] || [ -L "$old_conf" ]; then
            echo "发现旧配置文件: $old_conf"
            sudo rm -f "$old_conf"
            echo "已删除旧配置文件: $old_conf"
        fi
    done
fi

if [ -f "$config_file" ] || [ -L "$enabled_file" ]; then
    echo "发现旧配置文件，准备删除..."
    if confirm_default_yes "是否删除旧的Nginx配置文件？"; then
        sudo rm -f "$config_file" "$enabled_file"
        echo "旧配置文件已删除"
    else
        echo "保留旧配置文件，可能导致配置冲突"
    fi
fi

# 更新系统并安装必要的软件
echo "正在更新系统并安装Nginx和Certbot..."
sudo $PKG_UPDATE && sudo $PKG_INSTALL nginx certbot python3-certbot-nginx || {
    echo "软件安装失败" >&2
    exit 1
}

# 创建主网站目录
echo "正在创建网站目录..."
sudo mkdir -p "/var/www/${domain}/html" || {
    echo "创建目录失败" >&2
    exit 1
}

# 为www域名创建符号链接到主域名目录
sudo ln -sf "/var/www/${domain}" "/var/www/${www_domain}"

# 为每个子域名创建目录
for sub in "${subdomains[@]}"; do
    sudo mkdir -p "/var/www/${sub}/html" || {
        echo "创建子域名目录失败: ${sub}" >&2
        exit 1
    }
done

# 创建示例页面
echo "正在创建示例页面..."
echo "<html><body><h1>Welcome to ${domain}!</h1></body></html>" | sudo tee "/var/www/${domain}/html/index.html" >/dev/null

# 为每个子域名创建示例页面
for sub in "${subdomains[@]}"; do
    echo "<html><body><h1>Subdomain - ${sub}!</h1></body></html>" | sudo tee "/var/www/${sub}/html/index.html" >/dev/null
done

# 设置权限
echo "正在设置文件权限..."
sudo chown -R www-data:www-data "/var/www/${domain}"
sudo chmod -R 755 /var/www

# 为每个子域名设置权限
for sub in "${subdomains[@]}"; do
    sudo chown -R www-data:www-data "/var/www/${sub}"
done

# 创建Nginx配置文件
echo "正在创建Nginx配置文件..."

# 主域名和www域名配置
cat > "${config_file}" <<EOF
# 主域名和www域名配置
server {
    listen 80;
    listen [::]:80;
    
    server_name ${domain} ${www_domain};
    
    root /var/www/${domain}/html;
    
    location / {
        index index.html index.htm index.php;
        try_files \$uri \$uri/ =404;
    }
    
    # 通用的错误页面
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}

EOF

# 为每个子域名添加单独的server块
for sub in "${subdomains[@]}"; do
    cat >> "${config_file}" <<EOF
# 子域名 ${sub} 配置
server {
    listen 80;
    listen [::]:80;
    
    server_name ${sub};
    
    root /var/www/${sub}/html;
    
    location / {
        index index.html index.htm index.php;
        try_files \$uri \$uri/ =404;
    }
    
    # 通用的错误页面
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}

EOF
done

# 启用网站配置
echo "正在启用网站配置..."
if [ "$NGINX_AVAILABLE" != "$NGINX_ENABLED" ]; then
    sudo ln -sf "${config_file}" "${enabled_file}" || {
        echo "启用配置失败，可能配置已存在" >&2
    }
fi

# 检查Nginx配置
echo "正在检查Nginx配置..."
if ! sudo nginx -t; then
    echo "Nginx配置检查失败，生成的配置文件如下："
    cat "${config_file}"
    exit 1
fi

# 检查端口占用情况
echo "正在检查端口占用情况..."
if command -v netstat >/dev/null 2>&1; then
    echo "端口80占用情况："
    sudo netstat -tulpn | grep ':80 ' || echo "端口80未被占用"
    echo "端口443占用情况："
    sudo netstat -tulpn | grep ':443 ' || echo "端口443未被占用"
elif command -v ss >/dev/null 2>&1; then
    echo "端口80占用情况："
    sudo ss -tulpn | grep ':80 ' || echo "端口80未被占用"
    echo "端口443占用情况："
    sudo ss -tulpn | grep ':443 ' || echo "端口443未被占用"
else
    echo "无法检查端口占用情况，netstat和ss命令均不可用"
fi

# 尝试停止Nginx服务
echo "正在停止Nginx服务..."
sudo systemctl stop nginx

# 等待Nginx完全停止
echo "等待Nginx完全停止..."
sleep 2

# 重启Nginx
echo "正在重启Nginx..."
if ! sudo systemctl start nginx; then
    echo "Nginx启动失败，正在获取详细错误信息..."
    echo "===== Nginx状态信息 ====="
    sudo systemctl status nginx
    echo "===== Nginx日志信息 ====="
    sudo journalctl -xeu nginx.service --no-pager | tail -n 50
    
    echo "===== Nginx错误日志 ====="
    sudo cat /var/log/nginx/error.log | tail -n 50 || echo "无法读取Nginx错误日志"
    
    echo -e "\n尝试解决常见问题..."
    
    # 检查是否有其他进程占用80/443端口
    echo "检查是否有其他进程占用Web端口..."
    if command -v lsof >/dev/null 2>&1; then
        echo "端口80占用进程："
        sudo lsof -i :80 || echo "没有进程占用端口80"
        echo "端口443占用进程："
        sudo lsof -i :443 || echo "没有进程占用端口443"
    fi
    
    # 检查SELinux状态（如果存在）
    if command -v getenforce >/dev/null 2>&1; then
        echo "SELinux状态: $(getenforce)"
        echo "如果SELinux为Enforcing，可能需要调整策略或临时禁用"
    fi
    
    # 检查防火墙状态
    if command -v ufw >/dev/null 2>&1; then
        echo "UFW防火墙状态:"
        sudo ufw status
    elif command -v firewall-cmd >/dev/null 2>&1; then
        echo "Firewalld防火墙状态:"
        sudo firewall-cmd --state
        echo "端口开放情况:"
        sudo firewall-cmd --list-all
    fi
    
    # 提示用户可能的解决方案
    echo -e "\n可能的解决方案："
    echo "1. 检查是否有其他Web服务器（如Apache）正在运行并占用端口"
    echo "2. 确保Nginx进程已完全停止: sudo pkill nginx"
    echo "3. 检查Nginx配置文件是否有语法之外的问题"
    echo "4. 检查系统资源是否充足（内存、磁盘空间等）"
    echo "5. 检查SELinux或AppArmor是否阻止了Nginx访问某些文件"
    
    echo -e "\n选择操作："
    echo "1) 强制停止所有Nginx进程并重新启动"
    echo "2) 尝试使用nginx二进制文件直接启动（调试模式）"
    echo "3) 继续尝试配置SSL证书（即使Nginx未运行）"
    echo "4) 退出脚本"
    
    read -p "请选择操作 [1-4]: " action_choice
    case $action_choice in
        1)
            echo "强制停止所有Nginx进程..."
            sudo pkill -9 nginx
            sleep 2
            echo "重新启动Nginx..."
            if sudo systemctl start nginx; then
                echo "Nginx已成功启动！"
            else
                echo "Nginx仍然无法启动，请手动检查系统日志和配置。"
                if confirm_default_yes "是否继续尝试配置SSL证书？"; then
                    echo "将继续尝试配置SSL证书，但请注意，如果Nginx未正常运行，SSL配置可能会失败。"
                else
                    exit 1
                fi
            fi
            ;;
        2)
            echo "尝试使用nginx二进制文件直接启动（调试模式）..."
            sudo nginx -g "daemon off;" &
            NGINX_PID=$!
            sleep 5
            if kill -0 $NGINX_PID 2>/dev/null; then
                echo "Nginx已成功启动！按Ctrl+C终止..."
                kill $NGINX_PID
                echo "尝试通过systemd启动Nginx..."
                if sudo systemctl start nginx; then
                    echo "Nginx已成功通过systemd启动！"
                else
                    echo "通过systemd启动失败，但直接启动成功，可能是systemd配置问题。"
                    if confirm_default_yes "是否继续尝试配置SSL证书？"; then
                        echo "将继续尝试配置SSL证书。"
                    else
                        exit 1
                    fi
                fi
            else
                echo "直接启动Nginx也失败，可能是配置文件问题。"
                echo "尝试使用调试选项启动..."
                sudo nginx -t -c "${config_file}"
                if confirm_default_yes "是否继续尝试配置SSL证书？"; then
                    echo "将继续尝试配置SSL证书，但请注意，如果Nginx未正常运行，SSL配置可能会失败。"
                else
                    exit 1
                fi
            fi
            ;;
        3)
            echo "将继续尝试配置SSL证书，但请注意，如果Nginx未正常运行，SSL配置可能会失败。"
            ;;
        4|*)
            echo "退出脚本。"
            exit 1
            ;;
    esac
else
    echo "Nginx已成功启动！"
fi

# 构建Certbot参数
certbot_domains=""
for domain in "${all_domains[@]}"; do
    certbot_domains+="-d ${domain} "
done

# 获取SSL证书
echo "正在获取SSL证书..."
certbot_output=$(sudo certbot --nginx ${certbot_domains} 2>&1)
certbot_exit_code=$?

if [ $certbot_exit_code -ne 0 ]; then
    echo "获取SSL证书失败" >&2
    echo "Certbot输出信息："
    echo "$certbot_output"
    
    # 检查是否为DNS解析错误
    if echo "$certbot_output" | grep -i "dns problem" > /dev/null || \
       echo "$certbot_output" | grep -i "no valid ip addresses found" > /dev/null || \
       echo "$certbot_output" | grep -i "connection refused" > /dev/null; then
        echo -e "\n错误分析：无法解析到当前IP，请确认DNS解析是否已经配置正确。"
        echo "请确保所有域名（${all_domains[*]}）都已正确解析到本服务器的公网IP地址。"
        echo "DNS解析通常需要一些时间生效（从几分钟到48小时不等），请稍后再试。"
        
        # 显示当前服务器IP
        echo -e "\n当前服务器IP信息："
        curl -s ifconfig.me || wget -qO- ifconfig.me || echo "无法获取服务器公网IP"
        
        # 提供验证DNS解析的方法
        echo -e "\n您可以使用以下命令验证域名解析："
        for domain in "${all_domains[@]}"; do
            echo "dig +short ${domain} 或 nslookup ${domain}"
        done
    elif echo "$certbot_output" | grep -i "rate limit" > /dev/null; then
        echo -e "\n错误分析：Let's Encrypt速率限制。"
        echo "Let's Encrypt对每个域名有每周5次失败尝试的限制。"
        echo "请等待一段时间后再尝试，或使用测试模式：--staging"
    elif echo "$certbot_output" | grep -i "already being used" > /dev/null || \
         echo "$certbot_output" | grep -i "already exists" > /dev/null; then
        echo -e "\n错误分析：证书已存在或端口已被占用。"
        echo "可能已经有证书为这些域名签发，或者有其他进程正在使用相关端口。"
        echo "您可以尝试删除现有证书后重试：sudo certbot delete"
    else
        echo -e "\n请查看上述Certbot输出了解详细错误信息。"
        echo "您可以手动运行以下命令尝试获取证书："
        echo "sudo certbot --nginx ${certbot_domains}"
    fi
    
    echo -e "\n您的网站仍可通过HTTP访问，但未启用HTTPS"
else
    echo "SSL证书配置成功！"
    echo -e "\n配置完成！您的网站现在可以通过以下方式访问："
    for domain in "${all_domains[@]}"; do
        echo "- HTTP: http://${domain}"
        echo "- HTTPS: https://${domain}"
    done
fi

# 显示完成信息和下一步建议
echo -e "\n===== 部署总结 ====="
if [ $certbot_exit_code -eq 0 ]; then
    echo "✅ Nginx配置：成功"
    echo "✅ SSL证书：成功"
    echo -e "\n恭喜！您的网站已完全配置好，可以通过HTTP和HTTPS访问。"
    echo "下一步建议："
    echo "1. 设置SSL自动续期：sudo systemctl enable certbot.timer"
    echo "2. 测试SSL配置：https://www.ssllabs.com/ssltest/"
    echo "3. 配置网站内容：编辑 /var/www/${domain}/html/ 目录中的文件"
else
    echo "✅ Nginx配置：成功"
    echo "❌ SSL证书：失败"
    echo -e "\n您的网站已部分配置完成，目前只能通过HTTP访问。"
    echo "要启用HTTPS，请解决上述SSL证书问题后重新运行此脚本或手动配置SSL。"
fi

echo -e "\n感谢使用自动Nginx配置脚本！"    