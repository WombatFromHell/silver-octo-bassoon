#!/bin/sh

TAR=$(which tar)
RSYNC=$(which rsync)

BASE_DIR=/etc/libvirt
BACKUP_DIR=~/Downloads
DATE=$(date '+%m%d%Y_%H%M%S')
ARCHIVE="qemu-config-${DATE}.tar.gz"
STORAGE_DIR=/mnt/HOMENAS-Home/GDrive/Backups/linux-config/backups/configs/libvirt-backups


if [ -z "$1" ]; then
	echo "Preparing backup directory..."
	cd ${BACKUP_DIR}
	rm -rf qemu_tmp
	mkdir -p qemu_tmp
	mkdir -p qemu_tmp/qemu
	mkdir -p qemu_tmp/hooks

	echo "Backing up current QEMU configuration..."
	sudo cp -f ${BASE_DIR}/qemu/*.xml ${BACKUP_DIR}/qemu_tmp/qemu/
	sudo cp -f ${BASE_DIR}/hooks/qemu ${BACKUP_DIR}/qemu_tmp/hooks/
	sudo cp -f ${BASE_DIR}/libvirt.conf ${BACKUP_DIR}/qemu_tmp/
	sudo cp -f ${BASE_DIR}/qemu.conf ${BACKUP_DIR}/qemu_tmp/
	sudo chown -R $USER:$USER ${BACKUP_DIR}/qemu_tmp

	echo "Archiving..."
	tar czf ${ARCHIVE} ./qemu_tmp
	echo "Syncing archives to storage..."
	${RSYNC} -avHP ./qemu-config-*.tar.gz ${STORAGE_DIR}
	echo "Cleaning up..."
	rm -rf ${BACKUP_DIR}/qemu_tmp
	echo "Done!"
elif [ -r "$1" ]; then
	echo "Unarchiving backup..."
	cd ${BACKUP_DIR}
	rm -rf ${BACKUP_DIR}/qemu_tmp
	tar xzf "${1}" -C ${BACKUP_DIR}/
	echo "Restoring files and correcting permissions..."
	
	read -p "WARNING: THIS WILL OVERWRITE YOUR DOMAINS! Are you sure?" -n 1 -r
	if [[ $REPLY =~ ^[Yy]$ ]]; then
		cd ${BACKUP_DIR}/qemu_tmp
		chown -R root:root ${BACKUP_DIR}/qemu_tmp
		cp -f ${BACKUP_DIR}/qemu/*.xml ${BASE_DIR}/qemu/
		cp -f ${BACKUP_DIR}/hooks/qemu ${BASE_DIR}/hooks/
		mv ${BASE_DIR}/libvirt.conf ${BASE_DIR}/libvirt.conf.bak
		mv ${BASE_DIR}/qemu.conf ${BASE_DIR}/qemu.conf.bak
		cp -f ${BACKUP_DIR}/libvirt.conf ${BASE_DIR}/
		cp -f ${BACKUP_DIR}/qemu.conf ${BASE_DIR}/
		echo "Cleaning up..."
		rm -rf ${BACKUP_DIR}/qemu_tmp
		echo "Done!"
	else
		echo "Bailing out..."
	fi
fi
