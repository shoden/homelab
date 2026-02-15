#!/usr/bin/env bash

export MYSQL_ROOT_PASSWORD='changeme_root_password'
export MYSQL_PASSWORD='changeme_mysql_password'
export NEXTCLOUD_ADMIN_PASSWORD='changeme_admin_password'

if [ $# -eq 0 ]; then
	echo "Error: You need to pass a playbook file"
	exit
fi

echo "Running playbook $1..."
ansible-playbook -i inventory.ini $1
