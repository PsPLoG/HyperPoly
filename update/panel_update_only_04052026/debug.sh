#!/bin/bash
ROOT_FS_TYPE="$(sed -n -e 's|^/dev/\S\+ /overlay/lower \(btrfs\) .*$|\1|p' /proc/mounts)"
# test "$ROOT_FS_TYPE" == btrfs
CUR_VER=$(sed -n -e 's|.* FIRMWARE \([0-9]*\)"|\1|p' /home/debian/UI/qml/Settings.qml)
OVROOT=$(sudo which overlayroot-chroot)
mount | grep overlay
HAS_OVERLAY=$?
# check if we're already btrfs
echo "start debug.sh"
echo "start panel" > /usb_flash/panel_debugrun
if [ $CUR_VER -ge 400 ]; then
	# check if panel state is written or not
	echo "update is installed" >> /usb_flash/debugrun
    sync /usb_flash/debugrun
	echo "checking panel state"
	test -f /usb_flash/installed_panel 
	if [ $? -eq 0 ]; then
		echo "panel previously updated" >> /usb_flash/panel_debugrun
	else
		echo "0" > /usb_flash/installed_panel
	fi

	installed_version=$(cat /usb_flash/installed_panel)
	panel_version=$(cat /usb_flash/panel_version)
	if [ $panel_version -eq $installed_version ]; then
		exit 100
	else
		/bin/bash /usb_flash/copy_panel.sh
		echo $panel_version > /usb_flash/installed_panel
		reboot
	fi
else
	echo "update not yet installed" >> /usb_flash/panel_debugrun
fi
