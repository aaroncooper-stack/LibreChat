Here is the Dockerfile

# v0.8.8-rc2

# Base node image
FROM node:24.16.0-alpine AS node

RUN apk upgrade --no-cache
RUN apk add --no-cache jemalloc
RUN apk add --no-cache python3 py3-pip uv

# Set environment variable to use jemalloc
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2

# Add `uv` for extended MCP support
COPY --from=ghcr.io/astral-sh/uv:0.9.5-python3.12-alpine /usr/local/bin/uv /usr/local/bin/uvx /bin/
RUN uv --version

# Set configurable max-old-space-size with default
ARG NODE_MAX_OLD_SPACE_SIZE=6144
ARG NPM_CI_TIMEOUT_SECONDS=1500
ARG NPM_CI_ATTEMPTS=2

RUN mkdir -p /app && chown node:node /app
WORKDIR /app

USER node

COPY --chown=node:node package.json package-lock.json ./
COPY --chown=node:node api/package.json ./api/package.json
COPY --chown=node:node client/package.json ./client/package.json
COPY --chown=node:node packages/data-provider/package.json ./packages/data-provider/package.json
COPY --chown=node:node packages/data-schemas/package.json ./packages/data-schemas/package.json
COPY --chown=node:node packages/api/package.json ./packages/api/package.json

RUN \
    # Allow mounting of these files, which have no default
    touch .env ; \
    # Create directories for the volumes to inherit the correct permissions
    mkdir -p /app/client/public/images /app/logs /app/uploads /app/skill /app/data ; \
    chmod 1777 /app/data ; \
    npm config set fetch-retry-maxtimeout 600000 ; \
    npm config set fetch-retries 5 ; \
    npm config set fetch-retry-mintimeout 15000 ; \
    attempt=1 ; \
    until timeout "$NPM_CI_TIMEOUT_SECONDS" npm ci --no-audit ; do \
        status=$? ; \
        if [ "$attempt" -ge "$NPM_CI_ATTEMPTS" ]; then \
            exit "$status" ; \
        fi ; \
        echo "npm ci --no-audit failed with exit code $status; retrying attempt $((attempt + 1))/$NPM_CI_ATTEMPTS" ; \
        attempt=$((attempt + 1)) ; \
        npm cache clean --force || true ; \
        sleep 10 ; \
    done

COPY --chown=node:node . .

RUN \
    # React client build with configurable memory
    NODE_OPTIONS="--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE}" npm run frontend; \
    npm prune --production; \
    npm cache clean --force

# Optional build metadata surfaced in Settings -> About for support triage.
# Declared here (after the heavy install/build steps) so that commit/date
# changing on every CI run does not bust the cache for dependency install
# and frontend build layers. When unset, the backend falls back to local
# git resolution (if .git is present), and finally to empty values.
ARG BUILD_COMMIT=
ARG BUILD_BRANCH=
ARG BUILD_DATE=
ENV BUILD_COMMIT=${BUILD_COMMIT}
ENV BUILD_BRANCH=${BUILD_BRANCH}
ENV BUILD_DATE=${BUILD_DATE}

# Node API setup
#EXPOSE 3080
#ENV HOST=0.0.0.0

# Copy the yaml from the repo root to the app directory at runtime, then start backend
#CMD echo -e "version: '1.2'\ncache: true\nendpoints:\n  - name: openrouter\n    apiKey: '${OPENROUTER_KEY}'\n    models:\n      default:\n        - 'meta-llama/llama-3.3-70b-instruct'\n        - 'deepseek/deepseek-chat'" > /tmp/librechat.yaml && npm run backend
# Node API setup
EXPOSE 3080
ENV HOST=0.0.0.0

# Generate the config file dynamically at runtime to bypass image copy restrictions
#CMD printf "version: 1.3.15\ncache: true\nmemory:\n  disabled: false\n  personalize: true\n  tokenLimit: 2000\n  maxInputTokens: 12000\n  agent:\n    enabled: true\n    provider: \"openai\"\n    model: \"gpt-4o-mini\"\n    instructions: |\n      Store information only related to user preferences, important facts, and ongoing tasks.\nendpoints:\n  custom:\n    - name: \"OpenRouter\"\n      apiKey: \"\${OPENROUTER_KEY}\"\n      baseURL: \"https://openrouter.ai/api/v1\"\n      models:\n        default: \n          - \"meta-llama/llama-3.3-70b-instruct\"\n          - \"deepseek/deepseek-chat\"\n        fetch: true\n      titleConvo: true\n      titleModel: \"meta-llama/llama-3.3-70b-instruct\"\n      dropParams: [\"stop\"]\n      modelDisplayLabel: \"OpenRouter\"\n" > /app/librechat.yaml && npm 
# Optional: for client with nginx routing
# FROM nginx:stable-alpine AS nginx-client
# WORKDIR /usr/share/nginx/html
# COPY --from=node /app/client/dist /usr/share/nginx/html
# COPY client/nginx.conf /etc/nginx/conf.d/default.conf
# ENTRYPOINT ["nginx", "-g", "daemon off;"]
