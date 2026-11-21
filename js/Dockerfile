# ---- 构建阶段：装依赖（node-pty 需要编译工具，失败也不影响主功能）----
FROM node:20-slim AS build
WORKDIR /app
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ \
 && rm -rf /var/lib/apt/lists/*
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

# ---- 运行阶段：只带代码和 node_modules ----
FROM node:20-slim
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3000
COPY --from=build /app/node_modules ./node_modules
COPY package.json index.js ./
EXPOSE 3000
CMD ["node", "index.js"]
