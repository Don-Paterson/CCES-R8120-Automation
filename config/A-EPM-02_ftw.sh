# ---------------------------------------------------------------------------
# CCES R81.20 lab - First Time Wizard answer file for A-EPM-02
# SECONDARY Endpoint Security Management Server (Lab 6B, Task 6B-1)
#
# Before running this:
#   1. In SmartConsole on A-EPM, create the Secondary Security Management
#      Server object for A-EPM-02 (10.1.1.104) and set a one-time password.
#   2. Put that same one-time password in ftw_sic_key below.
#
# Validate with:  config_system -f A-EPM-02_ftw.sh --dry-run
# ---------------------------------------------------------------------------

install_security_gw="false"
gateway_daip="false"
gateway_cluster_member="false"
install_security_managment="true"
install_mgmt_primary="false"
install_mgmt_secondary="true"

# SIC one-time password shared with the primary (A-EPM). Must match SmartConsole.
ftw_sic_key="Chkp!234"

download_info="true"
download_from_checkpoint_non_security="true"
upload_info="true"
upload_crash_data="false"

# Administrator / GUI client parameters are primary-only. A secondary server takes
# its administrators from the primary once SIC is established, so they are left out
# here. If your build of config_system insists on them, uncomment the block below -
# --dry-run will tell you.
# mgmt_admin_radio="new_admin"
# mgmt_admin_name="cpadmin"
# mgmt_admin_passwd="Chkp!234"
mgmt_gui_clients_radio="network"
mgmt_gui_clients_ip_field="10.1.1.0"
mgmt_gui_clients_subnet_field="24"

iface="eth0"
ipstat_v4=manually
ipaddr_v4="10.1.1.104"
masklen_v4="24"
default_gw_v4="10.1.1.1"

hostname="A-EPM-02"
domainname="alpha.cp"
timezone="Europe/London"

ntp_primary="ntp.checkpoint.com"
ntp_primary_version="3"
ntp_secondary="ntp2.checkpoint.com"
ntp_secondary_version="3"

primary="192.168.11.101"
secondary="9.9.9.9"
tertiary="1.1.1.1"

# Some R81.20 builds also want a maintenance-mode password hash. If --dry-run asks
# for it, generate one on any Gaia box with:  grub2-mkpasswd-pbkdf2
# and uncomment:
# maintenance_hash="<hash>"

reboot_if_required="true"
