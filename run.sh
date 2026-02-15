#!/usr/bin/env bash

export MYSQL_ROOT_PASSWORD='changeme_root_password'
export MYSQL_PASSWORD='changeme_mysql_password'
export NEXTCLOUD_ADMIN_PASSWORD='changeme_admin_password'

echo "Running playbook..."
ansible-playbook -i inventory.ini playbook.yml
