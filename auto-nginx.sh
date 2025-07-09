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

read -p "是否继续? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "操作已取消"
    exit 1
fi

# 更新系统并安装必要的软件
echo "正在更新系统并安装Nginx和Certbot..."
sudo apt update && sudo apt install -y nginx certbot python3-certbot-nginx || {
    echo "软件安装失败" >&2
    exit 1
}

# 创建主网站目录
echo "正在创建网站目录..."
sudo mkdir -p "/var/www/${domain}/html" || {
    echo "创建目录失败" >&2
    exit 1
}

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
sudo chown -R www-data:www-data "/var/www/${domain}/html"
sudo chmod -R 755 /var/www

# 为每个子域名设置权限
for sub in "${subdomains[@]}"; do
    sudo chown -R www-data:www-data "/var/www/${sub}/html"
done

# 创建Nginx配置文件
echo "正在创建Nginx配置文件..."
cat > "/etc/nginx/sites-available/${domain}" <<EOF
server {
    listen 80;
    server_name $(printf "%s " "${all_domains[@]}");

    # 主域名配置
    location / {
        root /var/www/${domain}/html;
        index index.html index.htm;
        try_files \$uri \$uri/ =404;
    }

    # 子域名配置
    $(for sub in "${subdomains[@]}"; do
cat <<SUB_LOCATION
    location ~ ^/(.*)\$ {
        if (\$host = ${sub}) {
            set \$sub_path /\$1;
            root /var/www/${sub}/html;
            index index.html index.htm;
            try_files \$sub_path \$sub_path/ =404;
            break;
        }
    }
SUB_LOCATION
done)
}
EOF

# 启用网站配置
echo "正在启用网站配置..."
sudo ln -s "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/" || {
    echo "启用配置失败，可能配置已存在" >&2
}

# 检查Nginx配置
echo "正在检查Nginx配置..."
if ! sudo nginx -t; then
    echo "Nginx配置检查失败，生成的配置文件如下："
    cat "/etc/nginx/sites-available/${domain}"
    exit 1
fi

# 重启Nginx
echo "正在重启Nginx..."
sudo systemctl restart nginx || {
    echo "重启Nginx失败" >&2
    exit 1
}

# 构建Certbot参数
certbot_domains=""
for domain in "${all_domains[@]}"; do
    certbot_domains+="-d ${domain} "
done

# 获取SSL证书
echo "正在获取SSL证书..."
if ! sudo certbot --nginx ${certbot_domains}; then
    echo "获取SSL证书失败" >&2
    echo "您的网站仍可通过HTTP访问，但未启用HTTPS"
else
    echo "SSL证书配置成功！"
fi

echo -e "\n配置完成！您的网站现在可以通过以下方式访问："
for domain in "${all_domains[@]}"; do
    echo "- HTTP: http://${domain}"
    echo "- HTTPS: https://${domain}"
done    