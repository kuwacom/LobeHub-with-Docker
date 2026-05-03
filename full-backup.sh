tar -cvzf backup-lobehub_$(date +%Y%m%d).tar.gz \
  --exclude='.git' \
  --exclude='.vscode' \
  --exclude='backup_lobehub_*.tar.gz' \
  .