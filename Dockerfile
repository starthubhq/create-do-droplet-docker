# Use a lightweight base image with curl & jq
FROM alpine:3.20

# Install curl and jq
RUN apk add --no-cache curl jq

# Set working directory
WORKDIR /app

# Copy entrypoint script
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Default command
CMD ["/app/entrypoint.sh"]