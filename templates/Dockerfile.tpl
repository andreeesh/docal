FROM wordpress:__PHP_IMAGE_TAG__

ARG HOST_UID=1000
ARG HOST_GID=1000
ARG MAX_UPLOAD_BYTES=2147483648

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libpng-dev libjpeg-dev libwebp-dev zip unzip git curl default-mysql-client \
    && docker-php-ext-configure gd --with-jpeg --with-webp \
    && docker-php-ext-install gd mysqli pdo pdo_mysql \
    && apt-get clean \
    && rm -rf /var/cache/apt/lists/*

RUN a2enmod rewrite expires headers reqtimeout

# Fallback for permalinks/REST API when .htaccess is missing the WordPress
# rewrite block (common on sites migrated with LiteSpeed Cache or similar).
RUN printf '%s\n' \
    '<Directory /var/www/html>' \
    '    <IfModule mod_rewrite.c>' \
    '        RewriteEngine On' \
    '        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]' \
    '        RewriteBase /' \
    '        RewriteRule ^index\.php$ - [L]' \
    '        RewriteCond %{REQUEST_FILENAME} !-f' \
    '        RewriteCond %{REQUEST_FILENAME} !-d' \
    '        RewriteRule . /index.php [L]' \
    '    </IfModule>' \
    '</Directory>' \
    > /etc/apache2/conf-available/docal-rewrite.conf \
 && a2enconf docal-rewrite

COPY --from=wordpress:cli /usr/local/bin/wp /usr/local/bin/wp

RUN printf '%s\n' \
    '<Directory /var/www/html>' \
    "    LimitRequestBody ${MAX_UPLOAD_BYTES}" \
    '</Directory>' \
    > /etc/apache2/conf-available/docal-upload-limit.conf \
 && a2enconf docal-upload-limit

RUN printf '%s\n' \
    'Timeout 3600' \
    'RequestReadTimeout body=0' \
    > /etc/apache2/conf-available/docal-timeouts.conf \
 && a2enconf docal-timeouts

# Remap www-data UID/GID so bind-mounted files are owned by the host user
RUN usermod -u ${HOST_UID} www-data \
 && groupmod -g ${HOST_GID} www-data \
 && find /var/www -not -user www-data -exec chown www-data:www-data {} +

WORKDIR /var/www/html

EXPOSE 80
