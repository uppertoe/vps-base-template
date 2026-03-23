#!/usr/bin/env bash
# The canonical version of this script lives in:
#   ansible/roles/backup/files/restore.sh
#
# It is installed to /opt/backup/restore.sh on the VPS by the backup Ansible role.
# Run it there, or copy it locally for development use.
#
# See ansible/roles/backup/ for the full role and configuration reference.
exec "$(dirname "$0")/../ansible/roles/backup/files/restore.sh" "$@"
