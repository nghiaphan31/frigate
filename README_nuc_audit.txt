NUC Audit — quick install/upgrade steps
======================================

1) Copy files
   sudo install -m 0755 /mnt/data/nuc_audit_commit.sh /opt/sys-audit/nuc_audit_commit.sh
   sudo install -m 0644 -D /mnt/data/override.conf /etc/systemd/system/nuc-audit.service.d/override.conf
   sudo install -m 0440 /mnt/data/99-nuc-audit-sudoers /etc/sudoers.d/99-nuc-audit

2) Reload systemd and run
   sudo systemctl daemon-reload
   sudo systemctl restart nuc-audit.service
   sudo systemctl status nuc-audit.service --no-pager
   journalctl -u nuc-audit.service -n 80 --no-pager

3) (Optional) Enable daily timer
   sudo systemctl enable --now nuc-audit.timer

Notes
-----
- GIT push uses the service's GIT_SSH_COMMAND OR falls back to a safe default.
- If you enable EMAIL_ENABLE=1, ensure you have a local mailer (mailutils/msmtp/sendmail) configured.
- Docker Compose section now avoids Go-template parsing errors.
- Sudoers entry allows passwordless smart/dmi reads; remove if undesired.
