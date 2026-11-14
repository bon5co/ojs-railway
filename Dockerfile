# Open Journal Systems (OJS) for Railway.
#
# OJS (github.com/pkp/ojs, GPL-3.0) is the Public Knowledge Project's journal management and publishing system:
# submissions, peer review, editorial workflow, publication, OAI-PMH and a REST API. This wrapper keeps the upstream
# pkpofficial/ojs image (Debian, Apache, PHP 8.3) unchanged and adds what a public Railway deploy driven by an agent needs.
#
# 1. Upstream's optional first-boot installer posts the hard-coded login admin / admin to the install form. The entrypoint
#    installs with the CLI installer and an admin password taken from OJS_ADMIN_PASSWORD, and refuses to start without one.
# 2. Apache listens on 80 from its own config and ignores Railway's injected PORT; the entrypoint rewrites the vhost.
# 3. OJS keeps its settings in config.inc.php inside the image, so the first install is lost on redeploy. The entrypoint
#    keeps config.inc.php, the files directory and the public directory on the one Railway volume mounted at /data.
# 4. Behind Railway's TLS edge the port-80 vhost never sees HTTPS; the entrypoint adds the X-Forwarded-Proto mapping
#    upstream only ships in its port-443 vhost, and sets base_url to the public https domain.
#
# upstream: pkp/ojs
FROM pkpofficial/ojs:3_5_0-6@sha256:0c26ece9e6af0c34961edfd2a187c5dc175ef5432b3d16d7c072de5d62d2c3f9

USER root
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

ENV OJS_ADMIN_USERNAME=admin \
    OJS_DB_USER=ojs \
    OJS_DB_NAME=ojs \
    OJS_ADMIN_EMAIL=admin@example.com

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["/usr/local/bin/apache2-foreground"]
