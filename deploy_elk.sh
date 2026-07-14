#!/bin/bash

# --- Configuration Variables ---
ELK_VERSION="8.x"
DPDK_NDPI_REPO="https://github.com/RajaMuhammadAwais/dpdk-ndpi-traffic-lab.git"
DPDK_NDPI_DIR="/home/ubuntu/dpdk-ndpi-traffic-lab"
LOGSTASH_CONF_PATH="/home/ubuntu/traffic_logstash.conf"
LOGSTASH_LOG_PATH="/home/ubuntu/logstash.log"

# --- Logging Functions ---
log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; exit 1; }

# --- Pre-check Function ---
check_prerequisites() {
    log_info "Checking prerequisites..."
    if [[ $(id -u) -ne 0 ]]; then
        log_error "This script must be run with sudo privileges."
    fi
    log_info "Prerequisites met."
}

# --- Step 1: Install Dependencies ---
install_dependencies() {
    log_info "Step 1: Installing system dependencies..."
    apt_update_output=$(sudo apt-get update 2>&1)
    if echo "$apt_update_output" | grep -q "E: "; then
        log_warn "apt-get update encountered errors, but continuing: $apt_update_output"
    else
        log_info "apt-get update successful."
    fi

    sudo apt-get install -y wget curl git openjdk-17-jre-headless || log_error "Failed to install core dependencies."
    log_info "System dependencies installed."
}

# --- Step 2: Install ELK Stack ---
install_elk() {
    log_info "Step 2: Installing ELK Stack components (Elasticsearch, Kibana, Logstash)..."

    # Add Elastic GPG key
    wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg || log_error "Failed to add Elastic GPG key."

    # Add Elastic APT repository
    echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/${ELK_VERSION}/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-${ELK_VERSION}.list || log_error "Failed to add Elastic APT repository."

    # Update apt cache again
    apt_update_output=$(sudo apt-get update 2>&1)
    if echo "$apt_update_output" | grep -q "E: "; then
        log_warn "apt-get update encountered errors, but continuing: $apt_update_output"
    else
        log_info "apt-get update successful."
    fi

    # Install ELK components
    sudo apt-get install -y elasticsearch kibana logstash || log_error "Failed to install Elasticsearch, Kibana, or Logstash."
    log_info "ELK Stack components installed."
}

# --- Step 3: Configure and Start Elasticsearch ---
configure_elasticsearch() {
    log_info "Step 3: Configuring and starting Elasticsearch..."

    # Configure network host and disable security for lab environment
    sudo sed -i 's/#network.host: 192.168.0.1/network.host: 0.0.0.0/' /etc/elasticsearch/elasticsearch.yml || log_error "Failed to configure Elasticsearch network host."
    sudo sed -i 's/xpack.security.enabled: true/xpack.security.enabled: false/' /etc/elasticsearch/elasticsearch.yml || log_error "Failed to disable Elasticsearch security."

    # Reload systemd, enable and start Elasticsearch
    sudo systemctl daemon-reload || log_error "Failed to reload systemd daemon."
    sudo systemctl enable elasticsearch.service || log_error "Failed to enable Elasticsearch service."
    sudo systemctl start elasticsearch.service || log_error "Failed to start Elasticsearch service."

    # Wait for Elasticsearch to be up
    log_info "Waiting for Elasticsearch to start..."
    until curl -s http://localhost:9200 > /dev/null; do
        sleep 5
    done
    log_info "Elasticsearch is up and running."
}

# --- Step 4: Configure and Start Kibana ---
configure_kibana() {
    log_info "Step 4: Configuring and starting Kibana..."

    # Configure Kibana host and Elasticsearch connection
    sudo sed -i 's/#server.host: "localhost"/server.host: "0.0.0.0"/' /etc/kibana/kibana.yml || log_error "Failed to configure Kibana server host."
    sudo sed -i 's/#elasticsearch.hosts: \[\"http:\/\/localhost:9200\"\]/elasticsearch.hosts: \[\"http:\/\/localhost:9200\"\]/' /etc/kibana/kibana.yml || log_error "Failed to configure Kibana Elasticsearch hosts."

    # Enable and start Kibana
    sudo systemctl enable kibana.service || log_error "Failed to enable Kibana service."
    sudo systemctl start kibana.service || log_error "Failed to start Kibana service."

    log_info "Kibana service started. It may take a few minutes to be fully accessible."
}

# --- Step 5: Build DPDK nDPI Traffic Analyzer ---
build_traffic_analyzer() {
    log_info "Step 5: Building DPDK nDPI Traffic Analyzer..."

    if [ ! -d "$DPDK_NDPI_DIR" ]; then
        log_info "Cloning dpdk-ndpi-traffic-lab repository..."
        git clone "$DPDK_NDPI_REPO" "$DPDK_NDPI_DIR" || log_error "Failed to clone dpdk-ndpi-traffic-lab repository."
    else
        log_info "dpdk-ndpi-traffic-lab repository already exists. Skipping clone."
    fi

    pushd "$DPDK_NDPI_DIR" > /dev/null || log_error "Failed to change directory to $DPDK_NDPI_DIR."
    log_info "Running setup.sh for DPDK nDPI..."
    sudo ./setup.sh || log_error "Failed to run dpdk-ndpi-traffic-lab setup script."
    log_info "Compiling dpdk-ndpi-traffic-lab..."
    make || log_error "Failed to compile dpdk-ndpi-traffic-lab."
    popd > /dev/null || log_error "Failed to return to previous directory."

    log_info "DPDK nDPI Traffic Analyzer built."
}

# --- Step 6: Configure and Start Logstash ---
configure_logstash() {
    log_info "Step 6: Configuring and starting Logstash..."

    # Create Logstash configuration file
    cat <<EOF | sudo tee "$LOGSTASH_CONF_PATH" > /dev/null
input {
  pipe {
    command => "sudo ${DPDK_NDPI_DIR}/main -l 0 --vdev=net_pcap0,iface=eth0 --no-huge --file-prefix=lab_prod"
  }
}

filter {
  if [message] =~ /^\[/ {
    grok {
      match => { "message" => "\\[%{IP:src_ip}:%{INT:src_port} <-> %{IP:dst_ip}:%{INT:dst_port}\\] Protocol: %{WORD:protocol}( \\| JA4: %{DATA:ja4_fingerprint})?" }
    }
    mutate {
      convert => {
        "src_port" => "integer"
        "dst_port" => "integer"
      }
    }
  } else if [message] =~ /SECURITY ALERT/ {
    grok {
      match => { "message" => "\\[!\\] SECURITY ALERT: %{GREEDYDATA:security_alert}" }
    }
    mutate {
      add_tag => [ "security_alert" ]
    }
  } else {
    drop { }
  }
}

output {
  elasticsearch {
    hosts => ["http://localhost:9200"]
    index => "network-traffic-%{+YYYY.MM.dd}"
  }
  stdout { codec => rubydebug }
}
EOF
    log_info "Logstash configuration created at $LOGSTASH_CONF_PATH."

    # Start Logstash in background
    sudo /usr/share/logstash/bin/logstash -f "$LOGSTASH_CONF_PATH" --path.settings /etc/logstash > "$LOGSTASH_LOG_PATH" 2>&1 &
    LOGSTASH_PID=$!
    log_info "Logstash started in the background with PID: $LOGSTASH_PID. Log file: $LOGSTASH_LOG_PATH."
    log_info "It may take a few moments for Logstash to fully initialize and start ingesting data."
}

# --- Main Execution Flow ---
main() {
    check_prerequisites
    install_dependencies
    install_elk
    configure_elasticsearch
    configure_kibana
    build_traffic_analyzer
    configure_logstash

    log_info "\nELK Stack and Traffic Analyzer deployment complete!"
    log_info "Kibana should be accessible at http://<your-server-ip>:5601 (or the exposed public URL)."
    log_info "Remember to create a Data View in Kibana for 'network-traffic-*' with '@timestamp' as the time field."
    log_info "For security, consider enabling X-Pack security in production environments."
}

main
