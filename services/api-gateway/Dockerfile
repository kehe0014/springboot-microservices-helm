# -----------------------------------------------------
# Stage 1 : Build
# -----------------------------------------------------
FROM eclipse-temurin:17-jdk-alpine AS builder

# Install tools (maven, curl, etc.)
RUN apk add --no-cache maven

# Define build arguments
ARG JAR_FILE=target/*.jar

WORKDIR /workspace/app

# Copy pom.xml and download dependencies first (layer caching)
COPY pom.xml .
COPY src src

# Build application (skip tests for faster builds in CI/CD, remove if not desired)
RUN mvn -B -DskipTests clean package

# -----------------------------------------------------
# Stage 2 : Runtime
# -----------------------------------------------------
FROM eclipse-temurin:17-jre-alpine AS runtime

# Security: Create non-root user
RUN addgroup -S spring && adduser -S spring -G spring

# Set working dir
WORKDIR /app

# Copy jar from build stage
COPY --from=builder /workspace/app/target/*.jar app.jar

# Expose port
EXPOSE 8080

# JVM optimizations for containers
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -Djava.security.egd=file:/dev/./urandom"

# Use non-root user
USER spring:spring

# Metadata labels (enterprise standard)
LABEL org.opencontainers.image.title="api-gateway" \
    org.opencontainers.image.version="1.0.0" \
    org.opencontainers.image.authors="tdksoftconsulting@tdksoft.com" \
    org.opencontainers.image.source="https://github.com/kehe0014/api-gateway" \
    org.opencontainers.image.licenses="Apache-2.0"

# Healthcheck (optionnel mais recommandé en production)
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost:8080/actuator/health || exit 1

# Launch the application
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
