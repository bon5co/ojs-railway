#!/bin/sh
# OJS on Railway: bind the injected PORT, keep state on one volume, install once from variables, serve over https.
set -eu

die() { echo "ojs-railway: $*" >&2; exit 1; }

: "${OJS_ADMIN_PASSWORD:?OJS_ADMIN_PASSWORD is empty - the admin account would have no usable password}"
[ "${#OJS_ADMIN_PASSWORD}" -ge 12 ] || die "OJS_ADMIN_PASSWORD must be at least 12 characters"
: "${OJS_SALT:?OJS_SALT is empty}"
: "${OJS_DB_HOST:?OJS_DB_HOST is empty}"
: "${OJS_DB_USER:?OJS_DB_USER is empty}"
: "${OJS_DB_PASSWORD:?OJS_DB_PASSWORD is empty}"
OJS_DB_NAME="${OJS_DB_NAME:-ojs}"
OJS_DB_PORT="${OJS_DB_PORT:-3306}"
PORT="${PORT:-8080}"

if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  BASE_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
else
  BASE_URL="${OJS_BASE_URL:-http://localhost:${PORT}}"
fi
SERVER_NAME="${BASE_URL#*://}"

HTML=/var/www/html
DATA=/data
CONF=$DATA/config.inc.php

mkdir -p "$DATA/files" "$DATA/public"
echo "ojs-railway: data dir owner before chown=$(stat -c %u:%g "$DATA") port=$PORT base_url=$BASE_URL"

# config.inc.php lives on the volume. First boot seeds it from the image copy, every boot links it back in.
if [ ! -f "$CONF" ]; then
  if [ -f "$HTML/config.TEMPLATE.inc.php" ]; then cp "$HTML/config.TEMPLATE.inc.php" "$CONF"; else cp "$HTML/config.inc.php" "$CONF"; fi
fi
runuser -u www-data -- rm -f "$HTML/config.inc.php"
runuser -u www-data -- ln -s "$CONF" "$HTML/config.inc.php"

# files directory (private uploads) and public directory (journal logos, covers) also live on the volume
if [ ! -L "$HTML/public" ]; then
  cp -a "$HTML/public/." "$DATA/public/" 2>/dev/null || true
  runuser -u www-data -- rm -rf "$HTML/public"
  runuser -u www-data -- ln -s "$DATA/public" "$HTML/public"
fi
chown -R www-data:www-data "$DATA"
chmod 640 "$CONF"
echo "ojs-railway: data dir owner after chown=$(stat -c %u:%g "$DATA")"

# Apache: bind PORT, and tell PHP the request was https when Railway's edge says so
sed -i "s/^Listen 80\$/Listen ${PORT}/" /etc/apache2/ports.conf
sed -i "s#<VirtualHost \*:80>#<VirtualHost *:${PORT}>#" /etc/apache2/conf-enabled/pkp.conf
if ! grep -q 'RAILWAY-HTTPS' /etc/apache2/conf-enabled/pkp.conf; then
  sed -i "0,/ServerName www.example.com/s##ServerName ${SERVER_NAME}\n\t\# RAILWAY-HTTPS\n\tSetEnvIf X-Forwarded-Proto \"^https\$\" HTTPS=on#" /etc/apache2/conf-enabled/pkp.conf
fi
sed -i "s/www.example.com/${SERVER_NAME}/g" /etc/apache2/conf-enabled/pkp.conf
echo "ServerName ${SERVER_NAME}" > /etc/apache2/conf-enabled/zz-servername.conf

setconf() { # key value  (replaces the first uncommented "key = ..." line)
  esc=$(printf '%s' "$2" | sed 's/[\\&|]/\\&/g')
  sed -i "0,/^$1[[:space:]]*=.*/s||$1 = \"$esc\"|" "$CONF"
}
setconf base_url "$BASE_URL"
setconf salt "$OJS_SALT"
setconf api_key_secret "$OJS_SALT"
setconf files_dir "$DATA/files"
sed -i "s/^restful_urls = Off/restful_urls = On/; s/^enable_cdn = On/enable_cdn = Off/" "$CONF"

# Host-header allowlist (OJS refuses any other Host with "400 Server host not allowed"): the public domain, Railway's
# healthcheck host, and the private name sibling services use
HOSTS="\"${SERVER_NAME%%:*}\",\"healthcheck.railway.app\""
[ -z "${RAILWAY_PRIVATE_DOMAIN:-}" ] || HOSTS="${HOSTS},\"${RAILWAY_PRIVATE_DOMAIN}\""
sethosts() { sed -i "s|^allowed_hosts[[:space:]]*=.*|allowed_hosts = '[${HOSTS}]'|" "$CONF"; }
sethosts

# wait for the database, then install exactly once
i=0
until php -r 'mysqli_report(MYSQLI_REPORT_OFF); $c=@mysqli_connect(getenv("OJS_DB_HOST"),getenv("OJS_DB_USER"),getenv("OJS_DB_PASSWORD"),getenv("OJS_DB_NAME"),(int)getenv("OJS_DB_PORT")); exit($c?0:1);' 2>/dev/null; do
  i=$((i+1)); [ "$i" -le 90 ] || die "database ${OJS_DB_HOST}:${OJS_DB_PORT} not reachable after 180s"
  sleep 2
done
export OJS_DB_HOST OJS_DB_USER OJS_DB_PASSWORD OJS_DB_NAME OJS_DB_PORT

if grep -q '^installed = Off' "$CONF"; then
  echo "ojs-railway: first boot, running the OJS installer"
  # installed = Off means no install ever finished, so any tables are a killed half-install; clear them or the retry fails
  php -r 'mysqli_report(MYSQLI_REPORT_OFF); $c=mysqli_connect(getenv("OJS_DB_HOST"),getenv("OJS_DB_USER"),getenv("OJS_DB_PASSWORD"),getenv("OJS_DB_NAME"),(int)getenv("OJS_DB_PORT")); mysqli_query($c,"SET FOREIGN_KEY_CHECKS=0"); $r=mysqli_query($c,"SHOW TABLES"); while($row=mysqli_fetch_row($r)){ mysqli_query($c,"DROP TABLE `".$row[0]."`"); }' || die "could not clear a half-installed database"
  # answers in the order tools/install.php asks: locale, additional locales, files dir, admin user, password x2,
  # admin email, driver, db host, db user, db password, db name, OAI id, beacon, confirm
  printf '%s\n' en "" "$DATA/files" "$OJS_ADMIN_USERNAME" "$OJS_ADMIN_PASSWORD" "$OJS_ADMIN_PASSWORD" "$OJS_ADMIN_EMAIL" \
    mysqli "$OJS_DB_HOST" "$OJS_DB_USER" "$OJS_DB_PASSWORD" "$OJS_DB_NAME" "${SERVER_NAME}" n y \
    | (cd "$HTML" && runuser -u www-data -- php tools/install.php) || die "installer failed"
  grep -q '^installed = On' "$CONF" || die "installer finished but installed is still Off"
  # the installer rewrites config.inc.php; put the deploy values back
  setconf base_url "$BASE_URL"
  setconf salt "$OJS_SALT"
  setconf api_key_secret "$OJS_SALT"
  setconf files_dir "$DATA/files"
  sethosts
  echo "ojs-railway: install complete"
else
  echo "ojs-railway: already installed"
fi
chown www-data:www-data "$CONF"

export SERVERNAME="$SERVER_NAME"
/usr/local/bin/pkp-pre-start >/dev/null

exec "$@"
