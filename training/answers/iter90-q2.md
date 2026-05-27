# Iter90 Q2 — Answer

**Question**: We run Kafka on Kubernetes. We want to add Debezium to stream Postgres changes into our pipeline. How does Debezium deploy on k8s — is it part of our Kafka pods or a separate pod?

---

## Answer

## What Debezium actually is

Debezium is not a standalone service — it's a **source connector plugin** that runs inside **Kafka Connect**, which is a separate framework for running connectors that move data into and out of Kafka. The architecture is:

- **Your existing Kafka pods**: store and serve messages (unchanged)
- **Kafka Connect pods** (new): a separate deployment that runs connector plugins
- **Debezium PostgresConnector**: the plugin running inside Kafka Connect that reads Postgres WAL and publishes change events to Kafka topics

You do **not** add Debezium to your existing Kafka pods. You add a **new Kafka Connect Deployment** alongside them.

## The Kubernetes architecture

```
Postgres (primary)
    ↓  [Debezium reads WAL via replication protocol]
Kafka Connect Pod(s)  ← Debezium PostgresConnector plugin lives here
    ↓  [publishes change events to Kafka topics]
Kafka (your existing cluster)
    ↓  [Spark Structured Streaming reads from Kafka]
Spark job → Iceberg on MinIO
```

## What Kubernetes resources you need to create

**1. Kafka Connect Deployment**

A separate pod running the Kafka Connect runtime with the Debezium Postgres connector JAR included. Use the official `debezium/connect` Docker image (which includes the Postgres plugin):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka-connect-debezium
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kafka-connect-debezium
  template:
    spec:
      containers:
      - name: connect
        image: debezium/connect:2.5   # includes Postgres plugin
        ports:
        - containerPort: 8083         # Kafka Connect REST API
        env:
        - name: BOOTSTRAP_SERVERS
          value: "kafka-service:9092"
        - name: GROUP_ID
          value: "debezium-connect-cluster"
        - name: CONFIG_STORAGE_TOPIC
          value: "_debezium_connect_configs"
        - name: OFFSET_STORAGE_TOPIC
          value: "_debezium_connect_offsets"
        - name: STATUS_STORAGE_TOPIC
          value: "_debezium_connect_status"
```

**2. Service** — exposes Kafka Connect's REST API (port 8083) so you can create/update connectors without kubectl exec:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kafka-connect-service
spec:
  selector:
    app: kafka-connect-debezium
  ports:
  - port: 8083
    targetPort: 8083
```

**3. Create the connector via the REST API** — after the pod is running, register the Debezium PostgresConnector via HTTP POST:

```bash
curl -X POST http://kafka-connect-service:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{
    "name": "postgres-debezium-connector",
    "config": {
      "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
      "database.hostname": "postgres-primary-service",
      "database.port": "5432",
      "database.user": "debezium_user",
      "database.password": "your-password",
      "database.dbname": "app",
      "database.server.name": "app-db",
      "plugin.name": "pgoutput",
      "slot.name": "debezium_slot",
      "publication.name": "debezium_pub",
      "table.include.list": "public.events,public.users,public.orders",
      "topic.prefix": "app-db"
    }
  }'
```

**4. Secret for credentials** — store Postgres credentials as a Kubernetes Secret rather than in the REST payload:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: debezium-postgres-credentials
type: Opaque
stringData:
  database.password: "your-postgres-password"
```

## Postgres prerequisites (before Kafka Connect will work)

Before the connector can connect, your Postgres primary needs:
- `wal_level = logical` in postgresql.conf (requires restart)
- `max_wal_senders` and `max_replication_slots` set to ≥ 1 (default 10 in modern Postgres)
- A pg_hba.conf entry for replication: `host replication debezium_user <connect-pod-ip>/32 scram-sha-256`
- A replication slot: `SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');`
- A publication: `CREATE PUBLICATION debezium_pub FOR TABLE events, users, orders;`
- The debezium_user role with: `ALTER ROLE debezium_user WITH REPLICATION;` + `GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium_user;`

## Summary

You need a separate **Kafka Connect Deployment** (not part of your existing Kafka pods) with the Debezium Postgres plugin. That pod reads from Postgres and writes change events into Kafka. Your Spark streaming job then consumes from those Kafka topics and merges changes into Iceberg using MERGE INTO. The Postgres-side prerequisites must be in place before the connector starts.
