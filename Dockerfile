FROM python:3.11-slim

WORKDIR /app

# Copy dependencies
COPY requirements.txt .

# Install dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY main.py .
COPY src/ src/

# Create directories for runtime data
RUN mkdir -p logs hooks

# Expose the webhook service port
EXPOSE 8080

# Set default environment variables
ENV LISTEN_HOST=0.0.0.0
ENV LISTEN_PORT=8080
ENV LOG_DEBUG=false

# Run the webhook service
CMD ["python", "main.py"]
