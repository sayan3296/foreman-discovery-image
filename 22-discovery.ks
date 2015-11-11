%post

echo " * ensure /etc/os-release is present (needed for RHEL 7.0)"
yum -y install fedora-release centos-release redhat-release-server || \
  touch /etc/os-release

echo " * disabling legacy network services (needed for RHEL 7.0)"
systemctl disable network.service

echo " * disabling kdump crash service"
systemctl disable kdump.service

echo " * configuring NetworkManager and udev/nm-prepare"
cat > /etc/NetworkManager/NetworkManager.conf <<'NM'
[main]
monitor-connection-files=yes
no-auto-default=*
#[logging]
#level=DEBUG
NM
cat > /etc/udev/rules.d/81-nm-prepare.rules <<'UDEV'
ACTION=="add", SUBSYSTEM=="net", NAME!="lo", RUN+="/usr/bin/systemd-cat -t nm-prepare /usr/bin/nm-prepare %k"
UDEV

echo " * configuring TFTP firewall modules"
echo -e "ip_conntrack_tftp\nnf_conntrack_netbios_ns" > /etc/modules-load.d/tftp-firewall.conf

echo " * enabling NetworkManager system services (needed for RHEL 7.0)"
systemctl enable NetworkManager.service
systemctl enable NetworkManager-dispatcher.service
systemctl enable NetworkManager-wait-online.service

echo " * enabling nm-prepare service"
systemctl enable nm-prepare.service

echo " * enabling required system services"
systemctl enable ipmi.service
systemctl enable foreman-proxy.service
systemctl enable discovery-fetch-extensions.path
systemctl enable discovery-menu.service

# register service is started manually from discovery-menu
systemctl disable discovery-register.service

echo " * disabling some unused system services"
systemctl disable ipmi.service

echo " * open foreman-proxy port via firewalld"
firewall-offline-cmd --zone=public --add-port=8443/tcp --add-port=8448/tcp

echo " * setting up foreman proxy service"
sed -i 's/After=.*/After=basic.target network-online.target nm-prepare.service/' /usr/lib/systemd/system/foreman-proxy.service
sed -i 's/Wants=.*/Wants=basic.target network-online.target nm-prepare.service/' /usr/lib/systemd/system/foreman-proxy.service
sed -i '/\[Unit\]/a ConditionPathExists=/etc/NetworkManager/system-connections/primary' /usr/lib/systemd/system/foreman-proxy.service
sed -i '/\[Service\]/a EnvironmentFile=-/etc/default/discovery' /usr/lib/systemd/system/foreman-proxy.service
sed -i '/\[Service\]/a ExecStartPre=/usr/bin/generate-proxy-cert' /usr/lib/systemd/system/foreman-proxy.service
sed -i '/\[Service\]/a PermissionsStartOnly=true' /usr/lib/systemd/system/foreman-proxy.service
/sbin/usermod -a -G tty foreman-proxy

cat >/etc/foreman-proxy/settings.yml <<'CFG'
---
:settings_directory: /etc/foreman-proxy/settings.d

# certificate is generated by /usr/bin/generate-proxy-cert
:ssl_certificate: /etc/foreman-proxy/cert.pem
:ssl_ca_file: /etc/foreman-proxy/cert.pem
:ssl_private_key: /etc/foreman-proxy/key.pem

:daemon: true
:http_port: 8448
:https_port: 8443

# SYSLOG cannot be used, see: http://projects.theforeman.org/issues/11623
# :log_file: SYSLOG
:log_file: /tmp/proxy.log
:log_level: DEBUG
CFG

cat >/etc/foreman-proxy/settings.d/discovery_image.yml <<'CFG'
---
:enabled: true
CFG

cat >/etc/foreman-proxy/settings.d/bmc.yml <<'CFG'
---
:enabled: true
:bmc_default_provider: shell
CFG

echo " * setting up systemd"
echo "DefaultTimeoutStartSec=30s" >> /etc/systemd/system.conf
echo "DefaultTimeoutStopSec=5s" >> /etc/systemd/system.conf
echo "DumpCore=no" >> /etc/systemd/system.conf

echo " * setting multi-user.target as default"
systemctl set-default multi-user.target

echo " * setting up journald and ttys"
systemctl disable getty@tty1.service getty@tty2.service
systemctl mask getty@tty1.service getty@tty2.service
echo "SystemMaxUse=15M" >> /etc/systemd/journald.conf
echo "ForwardToSyslog=no" >> /etc/systemd/journald.conf
echo "ForwardToConsole=no" >> /etc/systemd/journald.conf
systemctl enable journalctl.service

echo " * configuring foreman-proxy"
sed -i 's|.*:log_file:.*|:log_file: SYSLOG|' /etc/foreman-proxy/settings.yml
# facts API is disabled by default
echo -e "---\n:enabled: true" > /etc/foreman-proxy/settings.d/facts.yml
/sbin/usermod -a -G tty foreman-proxy

echo " * setting suid bits"
chmod +s /sbin/ethtool
chmod +s /usr/sbin/dmidecode
chmod +s /usr/bin/ipmitool

# Add foreman-proxy user to sudo and disable interactive tty for reboot
echo " * setting up sudo"
sed -i -e 's/^Defaults.*requiretty/Defaults !requiretty/g' /etc/sudoers
echo "foreman-proxy ALL=NOPASSWD: /sbin/shutdown" >> /etc/sudoers
echo "foreman-proxy ALL=NOPASSWD: /usr/sbin/kexec" >> /etc/sudoers

echo " * dropping some friendly aliases"
echo "alias vim=vi" >> /root/.bashrc
echo "alias halt=poweroff" >> /root/.bashrc
echo "alias 'rpm=echo DO NOT USE RPM; rpm'" >> /root/.bashrc
echo "alias 'yum=echo DO NOT USE YUM; yum'" >> /root/.bashrc

# Base env for extracting zip extensions
mkdir -p /opt/extension/{bin,lib,lib/ruby,facts}

%end
