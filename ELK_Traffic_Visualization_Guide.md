# ELK Stack for Real-time Network Traffic Visualization with DPDK and nDPI

## Introduction

This comprehensive guide details the setup of an **ELK Stack** (Elasticsearch, Logstash, Kibana) for **real-time network traffic visualization**. We will integrate it with a high-performance **DPDK (Data Plane Development Kit)** and **nDPI (Deep Packet Inspection)** based traffic analyzer to provide deep insights into network flows, protocols, and security alerts. This setup is ideal for network monitoring, security analysis, and performance troubleshooting in high-throughput environments.

### Keywords for SEO:
* ELK Stack Tutorial
* Elasticsearch Kibana Logstash Setup
* Real-time Network Traffic Analysis
* DPDK nDPI Integration
* Network Visualization Dashboard
* Deep Packet Inspection with ELK
* Traffic Monitoring Solution
* Network Security Analytics

## Prerequisites

Before you begin, ensure you have:

*   A Linux-based system (Ubuntu 24.04 LTS recommended) with `sudo` privileges.
*   Internet connectivity for downloading packages.
*   Basic familiarity with Linux command-line operations.
*   The `dpdk-ndpi-traffic-lab` repository cloned to your system. This guide assumes it's located at `/home/ubuntu/dpdk-ndpi-traffic-lab`.

## Step 1: Install ELK Stack Components

We will install Elasticsearch, Kibana, and Logstash from the Elastic APT repositories. This ensures you get the latest stable versions.

```bash
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-8.x.list
sudo apt-get update
sudo apt-get install -y elasticsearch kibana logstash openjdk-17-jre-headless curl
```

**Note**: The installation process can take a significant amount of time due to the large size of the packages. Please be patient.

## Step 2: Configure and Start Elasticsearch

We will configure Elasticsearch to be accessible from any IP address and disable security for ease of setup in a lab environment. For production, robust security measures are highly recommended.

```bash
sudo sed -i 's/#network.host: 192.168.0.1/network.host: 0.0.0.0/' /etc/elasticsearch/elasticsearch.yml
sudo sed -i 's/xpack.security.enabled: true/xpack.security.enabled: false/' /etc/elasticsearch/elasticsearch.yml
sudo systemctl daemon-reload
sudo systemctl enable elasticsearch.service
sudo systemctl start elasticsearch.service
```

Verify Elasticsearch status:

```bash
curl -X GET "localhost:9200/?pretty"
```

You should see a JSON response indicating Elasticsearch is running.

## Step 3: Configure and Start Kibana

Kibana will be configured to listen on all network interfaces and connect to our Elasticsearch instance.

```bash
sudo sed -i 's/#server.host: "localhost"/server.host: "0.0.0.0"/' /etc/kibana/kibana.yml
sudo sed -i 's/#elasticsearch.hosts: \["http:\/\/localhost:9200"\]/elasticsearch.hosts: \["http:\/\/localhost:9200"\]/' /etc/kibana/kibana.yml
sudo systemctl enable kibana.service
sudo systemctl start kibana.service
```

## Step 4: Build the DPDK nDPI Traffic Analyzer

Navigate to the `dpdk-ndpi-traffic-lab` directory and build the project. The `setup.sh` script handles dependencies and nDPI compilation.

```bash
cd /home/ubuntu/dpdk-ndpi-traffic-lab
sudo ./setup.sh
make
```

## Step 5: Configure Logstash for Traffic Data Ingestion

Create a Logstash configuration file to parse the output from the `dpdk-ndpi-traffic-lab` analyzer and send it to Elasticsearch. This configuration will extract source/destination IPs and ports, protocol, and JA4 fingerprints, as well as security alerts.

Create the file `/home/ubuntu/traffic_logstash.conf` with the following content:

```conf
input {
  pipe {
    command => "sudo /home/ubuntu/dpdk-ndpi-traffic-lab/main -l 0 --vdev=net_pcap0,iface=eth0 --no-huge --file-prefix=lab_prod"
  }
}

filter {
  if [message] =~ /^\[/ {
    grok {
      match => { "message" => "\[%{IP:src_ip}:%{INT:src_port} <-> %{IP:dst_ip}:%{INT:dst_port}\] Protocol: %{WORD:protocol}( \| JA4: %{DATA:ja4_fingerprint})?" }
    }
    mutate {
      convert => {
        "src_port" => "integer"
        "dst_port" => "integer"
      }
    }
  } else if [message] =~ /SECURITY ALERT/ {
    grok {
      match => { "message" => "\[!\] SECURITY ALERT: %{GREEDYDATA:security_alert}" }
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
```

## Step 6: Start Logstash

Run Logstash with the created configuration file. This will start the traffic analyzer and begin ingesting data into Elasticsearch.

```bash
sudo /usr/share/logstash/bin/logstash -f /home/ubuntu/traffic_logstash.conf --path.settings /etc/logstash > /home/ubuntu/logstash.log 2>&1 &
```

You can monitor the Logstash output by checking the log file:

```bash
tail -f /home/ubuntu/logstash.log
```

## Step 7: Access Kibana and Create Data View

Kibana is now running and accessible. You will need to create a Data View (formerly Index Pattern) to visualize the ingested data.

1.  Open your web browser and navigate to the Kibana URL provided (e.g., `http://localhost:5601` or the exposed public URL).
2.  In Kibana, go to **Analytics > Discover**.
3.  Click on **"Create data view"**.
4.  For the **Index pattern**, enter `network-traffic-*`.
5.  For the **Time field**, select `@timestamp`.
6.  Give your Data View a name, e.g., "Network Traffic Data".
7.  Click **"Create data view"**.

## Step 8: Visualize Traffic Data

With the Data View created, you can now explore and visualize your network traffic data:

*   **Discover**: Explore raw traffic logs, filter by IP, protocol, or security alerts.
*   **Visualize**: Create various visualizations like pie charts for protocols, bar charts for top talkers, or tables for security alerts.
*   **Dashboard**: Combine multiple visualizations into a comprehensive network traffic dashboard.

### Example Visualizations:

*   **Protocol Distribution**: A pie chart showing the percentage of different protocols (e.g., JSON, TLS, HTTP).
*   **Top Source/Destination IPs**: Bar charts identifying the most active source and destination IP addresses.
*   **Security Alerts Over Time**: A line graph tracking the frequency of security alerts.

## Conclusion

You have successfully set up an ELK stack to ingest and visualize real-time network traffic data using DPDK and nDPI. This powerful combination provides unparalleled visibility into your network's performance and security posture. You can further enhance this setup by creating custom dashboards, alerts, and integrating with other security tools.

## References

*   [Elasticsearch Documentation](https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html)
*   [Kibana Documentation](https://www.elastic.co/guide/en/kibana/current/index.html)
*   [Logstash Documentation](https://www.elastic.co/guide/en/logstash/current/index.html)
*   [DPDK Official Website](https://www.dpdk.org/)
*   [nDPI GitHub Repository](https://github.com/ntop/nDPI)
*   [dpdk-ndpi-traffic-lab GitHub Repository](https://github.com/RajaMuhammadAwais/dpdk-ndpi-traffic-lab)
