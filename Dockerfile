FROM metabrainz/node:10 as bookbrainz-base

ARG DEPLOY_ENV
ARG GIT_COMMIT_SHA

ARG BUILD_DEPS=" \
    build-essential \
    python-dev \
    libpq-dev"

ARG RUN_DEPS=" \
    bzip2 \
    git \
    rsync"


RUN apt-get update && \
    apt-get install --no-install-suggests --no-install-recommends -y \
        $BUILD_DEPS $RUN_DEPS && \
    rm -rf /var/lib/apt/lists/*

# PostgreSQL client
RUN wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
ENV PG_MAJOR 12
RUN echo 'deb http://apt.postgresql.org/pub/repos/apt/ jessie-pgdg main' $PG_MAJOR > /etc/apt/sources.list.d/pgdg.list
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-$PG_MAJOR \
    && rm -rf /var/lib/apt/lists/*

# Clean up files that aren't needed for production
RUN apt-get remove -y $BUILD_DEPS && \
    apt-get autoremove -y
    
RUN useradd --create-home --shell /bin/bash bookbrainz

ARG BB_ROOT=/home/bookbrainz/bookbrainz-site
WORKDIR $BB_ROOT
RUN chown bookbrainz:bookbrainz $BB_ROOT

RUN echo $GIT_COMMIT_SHA > .git-version

# Files necessary to complete the JavaScript build
COPY scripts/ scripts/
COPY .babelrc ./
COPY .eslintrc.js ./
COPY .eslintignore ./
COPY webpack.client.js ./
COPY package.json ./
COPY package-lock.json ./

RUN npm install --no-audit

COPY static/ static/
COPY config/ config/
COPY sql/ sql/
COPY src/ src/


# Development target
FROM bookbrainz-base as bookbrainz-dev
ARG DEPLOY_ENV

CMD ["npm", "start"]

# Production target
FROM bookbrainz-base as bookbrainz-prod
ARG DEPLOY_ENV

COPY ./docker/$DEPLOY_ENV/rc.local /etc/rc.local
RUN chmod 755 /etc/rc.local

COPY ./docker/consul-template-webserver.conf /etc/consul-template-webserver.conf
COPY ./docker/$DEPLOY_ENV/webserver.command /etc/service/webserver/exec-command
RUN chmod +x /etc/service/webserver/exec-command
COPY ./docker/$DEPLOY_ENV/webserver.service /etc/service/webserver/run
RUN chmod 755 /etc/service/webserver/run
RUN touch /etc/service/webserver/down

# Set up cron jobs and DB dumps
RUN mkdir -p /home/bookbrainz/data/dumps

COPY ./docker/consul-template-cron.conf /etc/consul-template-cron.conf
COPY ./docker/cron.service /etc/service/cron/run
RUN touch /etc/service/cron/down

ADD ./docker/crontab /etc/cron.d/bookbrainz
RUN chmod 0644 /etc/cron.d/bookbrainz && crontab -u bookbrainz /etc/cron.d/bookbrainz

# Build JS project and assets
RUN ["npm", "run", "build"]
RUN ["npm", "prune", "--production"]

# API target
FROM bookbrainz-base as bookbrainz-webservice
ARG DEPLOY_ENV

COPY ./docker/$DEPLOY_ENV/rc.local /etc/rc.local
RUN chmod 755 /etc/rc.local

COPY ./docker/consul-template-webserver.conf /etc/consul-template-webserver.conf
COPY ./docker/$DEPLOY_ENV/webserver.command /etc/service/webserver/exec-command
RUN chmod +x /etc/service/webserver/exec-command
COPY ./docker/$DEPLOY_ENV/webserver.service /etc/service/webserver/run
RUN chmod 755 /etc/service/webserver/run
RUN touch /etc/service/webserver/down
# Build API JS
RUN ["npm", "run", "build-api-js"]
RUN ["npm", "prune", "--production"]