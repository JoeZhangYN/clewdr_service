#!/bin/bash
# 文件名: clewdr_service.sh
# 功能: ClewdR服务管理工具
# 使用方法: chmod +x clewdr_service.sh & sudo bash ./clewdr_service.sh

# 修改为你自己的clewdr目录
CLEWDR_DIR="/root/clewdr"

# 检查是否以root运行
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "请以root用户运行此脚本"
    return 1
  fi
  return 0
}

# 创建服务文件
create_service() {
  cat > /etc/systemd/system/clewdr.service << EOF
[Unit]
Description=ClewdR Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${CLEWDR_DIR}
ExecStart=${CLEWDR_DIR}/clewdr
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 /etc/systemd/system/clewdr.service
  systemctl daemon-reload
  echo "服务文件已创建"
  return 0
}

# 启动服务
start_service() {
  systemctl start clewdr.service
  echo "服务已启动"
  return 0
}

# 停止服务
stop_service() {
  systemctl stop clewdr.service
  echo "服务已停止"
  return 0
}

# 重启服务
restart_service() {
  systemctl restart clewdr.service
  echo "服务已重启"
  return 0
}

# 查看服务状态
status_service() {
  systemctl status clewdr.service
  return 0
}

# 启用开机自启
enable_service() {
  systemctl enable clewdr.service
  echo "服务已设置为开机自启"
  return 0
}

# 禁用开机自启
disable_service() {
  systemctl disable clewdr.service
  echo "服务已禁用开机自启"
  return 0
}

# 卸载服务
remove_service() {
  systemctl stop clewdr.service 2>/dev/null
  systemctl disable clewdr.service 2>/dev/null
  rm -f /etc/systemd/system/clewdr.service
  systemctl daemon-reload
  echo "服务已卸载"
  return 0
}

# 显示菜单
show_menu() {
  clear
  echo "==================================="
  echo "     ClewdR 服务管理工具      "
  echo "==================================="
  echo "1) 安装服务"
  echo "2) 启动服务"
  echo "3) 停止服务"
  echo "4) 重启服务"
  echo "5) 查看服务状态"
  echo "6) 启用开机自启"
  echo "7) 禁用开机自启"
  echo "8) 卸载服务"
  echo "0) 退出"
  echo "==================================="
}

# 主菜单处理函数
main_menu() {
  show_menu
  
  read -rp "请选择操作 [0-8]: " choice
  echo
  
  case $choice in
    1)
      create_service
      ;;
    2)
      start_service
      ;;
    3)
      stop_service
      ;;
    4)
      restart_service
      ;;
    5)
      status_service
      ;;
    6)
      enable_service
      ;;
    7)
      disable_service
      ;;
    8)
      remove_service
      ;;
    0)
      echo "退出脚本。"
      return 1  # 返回非零表示退出循环
      ;;
    *)
      echo "无效选项，请重新选择。"
      ;;
  esac
  
  echo
  read -n1 -rp "按任意键继续..." key
  return 0
}

# 检查root权限
check_root || exit 1

# 主循环
while true; do
  main_menu
  [ $? -ne 0 ] && break
done

echo "服务管理脚本执行完毕。"
exit 0