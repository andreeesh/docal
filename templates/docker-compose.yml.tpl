services:
  wordpress:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        HOST_UID: "${HOST_UID:-1000}"
        HOST_GID: "${HOST_GID:-1000}"
        MAX_UPLOAD_BYTES: "${MAX_UPLOAD_BYTES:-2147483648}"
    image: docal/wordpress-__SITE_SLUG__:latest
    container_name: docal-__SITE_SLUG__-wp
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      # These WORDPRESS_* vars are what the official image's entrypoint uses to
      # generate wp-config.php — but docal generates wp-config.php itself before
      # the container ever starts (see write_wp_config() in setup-wordpress.sh),
      # so the entrypoint's own config step is a no-op here. They're set anyway
      # for parity with plain `docker run wordpress` setups and in case
      # wp-config.php is ever missing (e.g. a fresh volume). WP_HOME, WP_SITEURL
      # and the memory-limit constants are defined directly inside wp-config.php
      # instead, since WORDPRESS_CONFIG_EXTRA would be silently ignored too.
      WORDPRESS_DB_HOST: localhost:/var/run/mysqld/mysqld.sock
      WORDPRESS_DB_NAME: __DB_NAME__
      WORDPRESS_DB_USER: __DB_USER__
      WORDPRESS_DB_PASSWORD: __DB_PASSWORD__
      WORDPRESS_TABLE_PREFIX: wp_
    volumes:
      - ./wordpress:/var/www/html
      - ./uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
      - db-socket:/var/run/mysqld
    labels:
      - traefik.enable=true
      - traefik.docker.network=docal-proxy
      - traefik.http.routers.__SITE_SLUG__.rule=Host("__SITE_SLUG__.__SITE_DOMAIN__")
      - traefik.http.routers.__SITE_SLUG__.entrypoints=websecure
      - traefik.http.routers.__SITE_SLUG__.tls=true
      - traefik.http.routers.__SITE_SLUG__.middlewares=__SITE_SLUG__-upload@docker
      - traefik.http.middlewares.__SITE_SLUG__-upload.buffering.maxRequestBodyBytes=__MAX_UPLOAD_BYTES__
      - traefik.http.middlewares.__SITE_SLUG__-upload.buffering.memRequestBodyBytes=10485760
      - traefik.http.services.__SITE_SLUG__.loadbalancer.server.port=80
    networks:
      - docal-proxy

  db:
    image: mysql:__MYSQL_IMAGE_TAG__
    container_name: docal-__SITE_SLUG__-db
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: __DB_NAME__
      MYSQL_USER: __DB_USER__
      MYSQL_PASSWORD: __DB_PASSWORD__
      MYSQL_ROOT_PASSWORD: __DB_PASSWORD__
    volumes:
      - db-data:/var/lib/mysql
      - db-socket:/var/run/mysqld
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p__DB_PASSWORD__"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s
    networks:
      - docal-proxy

  wp-init:
    image: wordpress:cli
    profiles:
      - init
    user: root
    depends_on:
      db:
        condition: service_healthy
      wordpress:
        condition: service_started
    working_dir: /var/www/html
    volumes:
      - ./wordpress:/var/www/html
      - db-socket:/var/run/mysqld
    environment:
      WORDPRESS_DB_HOST: localhost:/var/run/mysqld/mysqld.sock
      WORDPRESS_DB_NAME: __DB_NAME__
      WORDPRESS_DB_USER: __DB_USER__
      WORDPRESS_DB_PASSWORD: __DB_PASSWORD__
    # The base64 blob below is NOT obfuscation — it's a tiny PHP DB-connectivity
    # check (source decoded in the comment right above the `echo`). It has to be
    # base64 because docker-compose interpolates any bare `$identifier` in this
    # file (that's why every real shell `$` below is escaped as `$$`), and the
    # PHP source uses PHP variables like `$h`/`$p`/`$s` that compose would try
    # (and fail) to substitute if written out in plain text here.
    #
    # Decoded source of the blob:
    #   <?php
    #   mysqli_report(MYSQLI_REPORT_OFF);
    #   $h = getenv("WORDPRESS_DB_HOST");
    #   $p = 3306; $s = null;
    #   if (strpos($h, ":/") !== false) {
    #       // host:/path/to/socket.sock
    #       [$h, $s] = explode(":", $h, 2);
    #       $p = null;
    #   } elseif (strpos($h, ":") !== false) {
    #       // host:port
    #       [$h, $p] = explode(":", $h, 2);
    #       $p = (int) $p;
    #   }
    #   exit(@mysqli_connect(
    #       $h,
    #       getenv("WORDPRESS_DB_USER"),
    #       getenv("WORDPRESS_DB_PASSWORD"),
    #       getenv("WORDPRESS_DB_NAME"),
    #       $p,
    #       $s
    #   ) ? 0 : 1);
    #
    # Replaces `wp db check`, which fails against MySQL 8.x/9.x due to a
    # caching_sha2_password incompatibility with the bundled MariaDB client.
    entrypoint: >
      /bin/sh -c "
      echo 'PD9waHAgbXlzcWxpX3JlcG9ydChNWVNRTElfUkVQT1JUX09GRik7JGg9Z2V0ZW52KCJXT1JEUFJFU1NfREJfSE9TVCIpOyRwPTMzMDY7JHM9bnVsbDtpZihzdHJwb3MoJGgsIjovIikhPT1mYWxzZSl7JGI9ZXhwbG9kZSgiOiIsJGgsMik7JGg9JGJbMF07JHM9JGJbMV07JHA9bnVsbDt9ZWxzZWlmKHN0cnBvcygkaCwiOiIpIT09ZmFsc2UpeyRiPWV4cGxvZGUoIjoiLCRoLDIpOyRoPSRiWzBdOyRwPShpbnQpJGJbMV07fWV4aXQoQG15c3FsaV9jb25uZWN0KCRoLGdldGVudigiV09SRFBSRVNTX0RCX1VTRVIiKSxnZXRlbnYoIldPUkRQUkVTU19EQl9QQVNTV09SRCIpLGdldGVudigiV09SRFBSRVNTX0RCX05BTUUiKSwkcCwkcyk/MDoxKTsK' | base64 -d > /tmp/dbcheck.php;
      echo 'Waiting for database connection...';
      until php /tmp/dbcheck.php 2>/dev/null; do
        echo 'DB not ready, retrying in 3s...';
        sleep 3;
      done;
      TRIES=10;
      while [ $$TRIES -gt 0 ]; do
        OUT=$$(wp core install --allow-root --url=https://__SITE_SLUG__.__SITE_DOMAIN__ --title='__SITE_TITLE__' --admin_user=admin --admin_password=admin --admin_email=__ADMIN_EMAIL__ --skip-email 2>&1);
        RC=$$?;
        if [ $$RC -eq 0 ]; then echo 'WordPress installed.'; break; fi;
        if echo "$$OUT" | grep -qi 'already installed'; then echo 'WordPress was already installed.'; break; fi;
        if echo "$$OUT" | grep -qi 'Error establishing'; then TRIES=$$((TRIES-1)); echo 'WP-CLI DB error, retrying...'; sleep 2; continue; fi;
        echo "$$OUT";
        exit 1;
      done;
      [ $$TRIES -le 0 ] && { echo 'WP install failed after several attempts.'; exit 1; };
      echo 'WP_INIT_DONE';
      "
    networks:
      - docal-proxy

volumes:
  db-data:
  db-socket:

networks:
  docal-proxy:
    external: true
