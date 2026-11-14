# ojs-railway

Open Journal Systems (OJS 3.5.0-6, [pkp/ojs](https://github.com/pkp/ojs), GPL-3.0) wrapped for Railway: installs itself on first boot from variables, keeps `config.inc.php`, uploaded files and public files on one volume at `/data`, binds Railway's `PORT`, and serves over the edge's https. Published image: `ghcr.io/bon5co/ojs-railway`.

Required variables: `OJS_ADMIN_PASSWORD` (12+ characters), `OJS_SALT`, `OJS_DB_HOST`, `OJS_DB_USER`, `OJS_DB_PASSWORD`, optional `OJS_DB_NAME` (default `ojs`). Needs a MariaDB or MySQL database.
