#!/bin/bash
# ============================================
# 🧹 阿里云监控与安全服务一键卸载脚本
# 适用系统：CentOS / Debian / Ubuntu
# ============================================

echo ">>> 开始关闭阿里云监控与安全代理服务..."

# 停止常见服务
systemctl stop aliyun.service 2>/dev/null
systemctl stop cloudmonitor.service 2>/dev/null
systemctl stop aegis.service 2>/dev/null

systemctl disable aliyun.service 2>/dev/null
systemctl disable cloudmonitor.service 2>/dev/null
systemctl disable aegis.service 2>/dev/null

# 杀死相关进程
echo ">>> 杀死相关进程..."
for p in AliYunDun AliYunDunMonitor cloudmonitor aliyun-assist; do
  pkill -9 $p 2>/dev/null
done

# 卸载相关包
echo ">>> 卸载 RPM / DEB 包..."
if command -v rpm &>/dev/null; then
  rpm -e --nodeps aliyun-assist cloudmonitor 2>/dev/null
fi

if command -v apt-get &>/dev/null; then
  apt-get remove --purge -y aliyun-assist cloudmonitor 2>/dev/null
fi

# 删除残留文件
echo ">>> 删除残留文件..."
rm -rf /etc/aliyun* /usr/sbin/aliyun* /usr/local/share/aliyun* \
       /usr/local/cloudmonitor /usr/local/aegis /var/log/aliyun* \
       /usr/local/share/aegis /usr/local/share/cloudmonitor

# 防止后续上报流量（屏蔽监控上报IP）
echo ">>> 添加防火墙规则屏蔽上报流量..."
sudo iptables -A OUTPUT -d 100.100.0.0/16 -j DROP 2>/dev/null
sudo iptables -A OUTPUT -d arms.aliyuncs.com -j DROP 2>/dev/null

echo "✅ 完成！阿里云监控与安全服务已关闭并卸载。"
