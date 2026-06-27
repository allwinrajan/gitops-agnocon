root@controlplane:~/gitops-agnocon$ kubectl get pods -n postgres-cluster -w
NAME                         READY   STATUS    RESTARTS   AGE
postgres-service-primary-0   1/1     Running   0          2m24s
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n postgres-cluster postgres-service-primary-0 -- bash
Defaulted container "postgres" out of: postgres, fix-routing (init)
postgres-service-primary-0:/# psql -U postgres
psql (17.10)
Type "help" for help.

postgres=# 
postgres=# CREATE DATABASE failover_test;
CREATE DATABASE
postgres=# \c failover_test
You are now connected to database "failover_test" as user "postgres".
failover_test=# CREATE TABLE employees (
failover_test(#     id SERIAL PRIMARY KEY,
failover_test(#     name VARCHAR(100),
failover_test(#     department VARCHAR(50),
failover_test(#     salary NUMERIC(10,2),
failover_test(#     created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
failover_test(# );
CREATE TABLE
failover_test=# INSERT INTO employees (name, department, salary) VALUES
failover_test-# ('Alice', 'DevOps', 75000),
failover_test-# ('Bob', 'Platform', 80000),
failover_test-# ('Charlie', 'SRE', 82000),
failover_test-# ('David', 'Backend', 70000),
failover_test-# ('Eva', 'Database', 85000);
INSERT 0 5
failover_test=# SELECT * FROM employees;
 id |  name   | department |  salary  |         created_at         
----+---------+------------+----------+----------------------------
  1 | Alice   | DevOps     | 75000.00 | 2026-06-27 17:21:35.515308
  2 | Bob     | Platform   | 80000.00 | 2026-06-27 17:21:35.515308
  3 | Charlie | SRE        | 82000.00 | 2026-06-27 17:21:35.515308
  4 | David   | Backend    | 70000.00 | 2026-06-27 17:21:35.515308
  5 | Eva     | Database   | 85000.00 | 2026-06-27 17:21:35.515308
(5 rows)

failover_test=# \q
postgres-service-primary-0:/# exit
exit
root@controlplane:~/gitops-agnocon$ kubectl delete pod postgres-service-primary-0 -n postgres-cluster
pod "postgres-service-primary-0" deleted from postgres-cluster namespace
root@controlplane:~/gitops-agnocon$ kubectl get pods -n postgres-cluster -w
NAME                         READY   STATUS     RESTARTS   AGE
postgres-service-primary-0   0/1     Init:0/1   0          13s
postgres-service-primary-0   0/1     PodInitializing   0          32s
postgres-service-primary-0   1/1     Running           0          33s
^Croot@controlplane:~/gitops-agnoconkubectl exec -it -n postgres-cluster postgres-service-primary-0 -- psql -U postgres -d failover_test
Defaulted container "postgres" out of: postgres, fix-routing (init)
psql (17.10)
Type "help" for help.

failover_test=# SELECT * FROM employees;
 id |  name   | department |  salary  |         created_at         
----+---------+------------+----------+----------------------------
  1 | Alice   | DevOps     | 75000.00 | 2026-06-27 17:21:35.515308
  2 | Bob     | Platform   | 80000.00 | 2026-06-27 17:21:35.515308
  3 | Charlie | SRE        | 82000.00 | 2026-06-27 17:21:35.515308
  4 | David   | Backend    | 70000.00 | 2026-06-27 17:21:35.515308
  5 | Eva     | Database   | 85000.00 | 2026-06-27 17:21:35.515308
(5 rows)

failover_test=# 









root@controlplane:~/gitops-agnocon$ kubectl get pods -n postgres-cluster -w
NAME                           READY   STATUS     RESTARTS   AGE
postgres-service-primary-0     0/1     Init:0/1   0          32s
postgres-service-standby-0-0   0/1     Init:0/1   0          32s
postgres-service-standby-1-0   0/1     Init:0/1   0          32s
postgres-service-primary-0     0/1     PodInitializing   0          32s
postgres-service-primary-0     1/1     Running           0          33s
postgres-service-standby-1-0   0/1     PodInitializing   0          37s
postgres-service-standby-0-0   0/1     PodInitializing   0          37s
postgres-service-standby-1-0   1/1     Running           0          38s
^Croot@controlplane:~/gitops-agnocon$ kubectl get pods -n postgres-cluster -w
NAME                           READY   STATUS            RESTARTS   AGE
postgres-service-primary-0     1/1     Running           0          53s
postgres-service-standby-0-0   0/1     PodInitializing   0          53s
postgres-service-standby-1-0   1/1     Running           0          53s
postgres-service-standby-0-0   1/1     Running           0          64s
^Croot@controlplane:~/gitops-agnocon$ kubectl get pods -n postgres-cluster -w
NAME                           READY   STATUS    RESTARTS   AGE
postgres-service-primary-0     1/1     Running   0          68s
postgres-service-standby-0-0   1/1     Running   0          68s
postgres-service-standby-1-0   1/1     Running   0          68s
^Croot@controlplane:~/gitops-agnocon$ 
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n postgres-cluster postgres-service-primary-0 -- psql -U postgres
Defaulted container "postgres" out of: postgres, fix-routing (init)
psql (17.10)
Type "help" for help.

postgres=# CREATE DATABASE failover_test;
ERROR:  database "failover_test" already exists
postgres=# \c failover_test
You are now connected to database "failover_test" as user "postgres".
failover_test=# CREATE TABLE employees(
failover_test(#     id SERIAL PRIMARY KEY,
failover_test(#     name TEXT,
failover_test(#     department TEXT
failover_test(# );
ERROR:  relation "employees" already exists
failover_test=# 
failover_test=# 
failover_test=# CREATE DATABASE failover_test_1;
CREATE DATABASE
failover_test=# \c failover_test_1
You are now connected to database "failover_test_1" as user "postgres".
failover_test_1=# CREATE TABLE employees(
    id SERIAL PRIMARY KEY,
    name TEXT,
    department TEXT
);
CREATE TABLE
failover_test_1=# INSERT INTO employees(name, department)
failover_test_1-# VALUES
failover_test_1-# ('Allwin','DevOps'),
failover_test_1-# ('John','Platform'),
failover_test_1-# ('Alice','SRE');
INSERT 0 3
failover_test_1=# SELECT * FROM employees;
 id |  name  | department 
----+--------+------------
  1 | Allwin | DevOps
  2 | John   | Platform
  3 | Alice  | SRE
(3 rows)

failover_test_1=# \q
root@controlplane:~/gitops-agnocon$ 
root@controlplane:~/gitops-agnocon$ 
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n postgres-cluster postgres-service-standby-0-0 -- psql -U postgres
Defaulted container "postgres" out of: postgres, fix-routing (init)
psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: No such file or directory
        Is the server running locally and accepting connections on that socket?
command terminated with exit code 2
root@controlplane:~/gitops-agnocon$ kubectl get pods -n postgres-cluster -w
NAME                           READY   STATUS    RESTARTS   AGE
postgres-service-primary-0     1/1     Running   0          2m53s
postgres-service-standby-0-0   1/1     Running   0          2m53s
postgres-service-standby-1-0   1/1     Running   0          2m53s
^Croot@controlplane:~/gitops-agnoconkubectl exec -it -n postgres-cluster postgres-service-standby-1-0 -- psql -U postgres
Defaulted container "postgres" out of: postgres, fix-routing (init)
psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: No such file or directory
        Is the server running locally and accepting connections on that socket?
command terminated with exit code 2
root@controlplane:~/gitops-agnocon$ 
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n postgres-cluster postgres-service-standby-0-0 -- ps -ef
Defaulted container "postgres" out of: postgres, fix-routing (init)
PID   USER     TIME  COMMAND
    1 root      0:00 bash /scripts/standby-init.sh
  171 root      0:00 sleep 5
  172 root      0:00 ps -ef
root@controlplane:~/gitops-agnocon$ kubectl logs postgres-service-standby-0-0 -n postgres-cluster
Defaulted container "postgres" out of: postgres, fix-routing (init)
[entrypoint] POD_ROLE=standby
[entrypoint] Standby mode — delegating to standby-init.sh
[standby-init] Fresh PVC — running pg_basebackup from primary...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (59 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (58 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (57 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (56 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (55 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (54 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (53 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (52 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (51 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (50 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (49 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (48 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (47 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (46 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (45 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (44 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (43 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (42 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (41 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (40 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (39 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (38 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (37 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (36 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (35 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (34 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (33 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (32 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (31 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (30 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (29 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (28 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (27 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (26 retries left)...
root@controlplane:~/gitops-agnocon$ kubectl logs postgres-service-standby-0-0 -n postgres-cluster -c postgres
[entrypoint] POD_ROLE=standby
[entrypoint] Standby mode — delegating to standby-init.sh
[standby-init] Fresh PVC — running pg_basebackup from primary...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (59 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (58 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (57 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (56 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (55 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (54 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (53 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (52 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (51 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (50 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (49 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (48 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (47 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (46 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (45 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (44 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (43 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (42 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (41 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (40 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (39 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (38 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (37 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (36 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (35 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (34 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (33 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (32 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (31 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (30 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (29 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (28 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (27 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (26 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (25 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (24 retries left)...
postgres-cluster-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432 - no response
[standby-init] Waiting for primary (23 retries left)...
root@controlplane:~/gitops-agnocon$ kubectl describe pod postgres-service-standby-0-0 -n postgres-cluster
Name:             postgres-service-standby-0-0
Namespace:        postgres-cluster
Priority:         0
Service Account:  default
Node:             controlplane/172.30.1.2
Start Time:       Sat, 27 Jun 2026 17:37:47 +0000
Labels:           app=postgres
                  apps.kubernetes.io/pod-index=0
                  controller-revision-hash=postgres-service-standby-0-c668db5d7
                  postgres/pod=standby-0
                  role=standby
                  statefulset.kubernetes.io/pod-name=postgres-service-standby-0-0
Annotations:      <none>
Status:           Running
IP:               192.168.0.62
IPs:
  IP:           192.168.0.62
Controlled By:  StatefulSet/postgres-service-standby-0
Init Containers:
  fix-routing:
    Container ID:  containerd://b43e9f6c158de89522ca74700ca835f6ef27d8fc25e0d988004a80cd99e7a4e4
    Image:         alpine:3.19
    Image ID:      docker.io/library/alpine@sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1
    Port:          <none>
    Host Port:     <none>
    Command:
      /bin/sh
      -c
      echo "[fix-routing] Waiting for net1..."
      NET1_UP=0
      for i in $(seq 1 15); do
        if ip link show net1 2>/dev/null | grep -q "net1"; then
          echo "[fix-routing] net1 up on attempt $i"
          NET1_UP=1
          break
        fi
        echo "[fix-routing] $i/15 waiting..."; sleep 2
      done
      if [ "$NET1_UP" = "0" ]; then
        echo "[fix-routing] net1 not present (standby pod or multus disabled) — applying eth0 routes only"
      fi
      
      ETH0_IP=$(ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)
      echo "[fix-routing] eth0 IP: ${ETH0_IP}"
      
      # Detect eth0 gateway
      ETH0_GW=$(ip route show dev eth0 | awk '/^default/{print $3; exit}')
      if [ -z "$ETH0_GW" ]; then
        ip neigh show dev eth0 2>/dev/null | grep -q "169.254.1.1" && \
          ETH0_GW="169.254.1.1" && echo "[fix-routing] Calico GW detected"
      fi
      if [ -z "$ETH0_GW" ]; then
        ETH0_GW=$(ip route show | awk '/^default/{print $3; exit}')
        echo "[fix-routing] fallback GW: ${ETH0_GW:-none}"
      fi
      if [ -z "$ETH0_GW" ]; then
        echo "[fix-routing] WARNING: no gateway found — skipping route fix"; exit 0
      fi
      echo "[fix-routing] Using GW: ${ETH0_GW}"
      
      # ── Cluster CIDRs via eth0 (main table) ──────────────────────────────
      ip route add 10.244.0.0/16 via $ETH0_GW dev eth0 2>/dev/null \
        && echo "[fix-routing] pod CIDR added" || echo "[fix-routing] pod CIDR exists"
      ip route add 10.96.0.0/12 via $ETH0_GW dev eth0 2>/dev/null \
        && echo "[fix-routing] svc CIDR added" || echo "[fix-routing] svc CIDR exists"
      
      # ── Table 100: eth0 source routing (Envoy probe fix) ─────────────────
      ip route add default       via $ETH0_GW dev eth0 table 100 2>/dev/null || true
      ip route add 10.244.0.0/16 via $ETH0_GW dev eth0 table 100 2>/dev/null || true
      ip route add 10.96.0.0/12  via $ETH0_GW dev eth0 table 100 2>/dev/null || true
      ip rule  add from "$ETH0_IP" lookup 100 priority 100 2>/dev/null || true
      echo "[fix-routing] table 100: from $ETH0_IP -> eth0 (Envoy probe fix)"
      
      # ── Table 200: MacVLAN reply traffic (primary only) ───────────────────
      if [ "$NET1_UP" = "1" ]; then
        NET1_GW=$(ip route show dev net1 | grep default | head -1 | awk '{print $3}')
        if [ -n "$NET1_GW" ]; then
          ip route add default        via $NET1_GW dev net1  table 200 2>/dev/null || true
          ip route add 192.168.9.0/24 dev net1 scope link    table 200 2>/dev/null || true
          ip rule  add from 192.168.9.0/24 lookup 200 priority 200 2>/dev/null || true
          ip rule  add to   192.168.9.0/24 lookup 200 priority 201 2>/dev/null || true
          echo "[fix-routing] table 200: MacVLAN 192.168.9.0/24 -> net1 ($NET1_GW)"
          # Remove net1 default from main table — prevent MacVLAN hijack
          ip route del default via ${NET1_GW} dev net1 2>/dev/null \
            && echo "[fix-routing] removed net1 default from main table" \
            || echo "[fix-routing] net1 default already gone"
        else
          echo "[fix-routing] WARNING: NET1_GW not found — table 200 skipped"
        fi
      fi
      
      echo "[fix-routing] === ROUTES FINAL ==="
      ip route show
      echo "--- ip rules ---"
      ip rule show
      echo "[fix-routing] Done"
      
    State:          Terminated
      Reason:       Completed
      Exit Code:    0
      Started:      Sat, 27 Jun 2026 17:37:48 +0000
      Finished:     Sat, 27 Jun 2026 17:38:18 +0000
    Ready:          True
    Restart Count:  0
    Environment:    <none>
    Mounts:
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-7cfsg (ro)
Containers:
  postgres:
    Container ID:  containerd://81d22294588d2ed7a2bde293997460e05341bea035e7952e0dde15e64540562f
    Image:         timescale/timescaledb:latest-pg17
    Image ID:      docker.io/timescale/timescaledb@sha256:a3c98d699f1fdd4a9338bfccd9a499277053bde08b40c858fb2f21959ab9c3a0
    Port:          5432/TCP (postgres)
    Host Port:     0/TCP (postgres)
    Command:
      bash
      /scripts/entrypoint.sh
    State:          Running
      Started:      Sat, 27 Jun 2026 17:38:44 +0000
    Ready:          True
    Restart Count:  0
    Limits:
      cpu:     250m
      memory:  512Mi
    Requests:
      cpu:     100m
      memory:  256Mi
    Environment:
      POD_NAME:                       postgres-service-standby-0-0 (v1:metadata.name)
      POD_ROLE:                       standby
      POSTGRES_PASSWORD:              <set to the key 'postgres-password' in secret 'postgres-service-secret'>     Optional: false
      POSTGRES_REPLICATION_PASSWORD:  <set to the key 'replication-password' in secret 'postgres-service-secret'>  Optional: false
      PGDATA:                         /var/lib/postgresql/data/pgdata
    Mounts:
      /mnt/postgres-config from config (ro)
      /scripts from scripts (ro)
      /var/lib/postgresql/data from data (rw)
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-7cfsg (ro)
Conditions:
  Type                        Status
  PodReadyToStartContainers   True 
  Initialized                 True 
  Ready                       True 
  ContainersReady             True 
  PodScheduled                True 
Volumes:
  data:
    Type:       PersistentVolumeClaim (a reference to a PersistentVolumeClaim in the same namespace)
    ClaimName:  data-postgres-service-standby-0-0
    ReadOnly:   false
  config:
    Type:      ConfigMap (a volume populated by a ConfigMap)
    Name:      postgres-service-config
    Optional:  false
  scripts:
    Type:      ConfigMap (a volume populated by a ConfigMap)
    Name:      postgres-service-scripts
    Optional:  false
  kube-api-access-7cfsg:
    Type:                    Projected (a volume that contains injected data from multiple sources)
    TokenExpirationSeconds:  3607
    ConfigMapName:           kube-root-ca.crt
    Optional:                false
    DownwardAPI:             true
QoS Class:                   Burstable
Node-Selectors:              <none>
Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
Events:
  Type    Reason     Age    From               Message
  ----    ------     ----   ----               -------
  Normal  Scheduled  4m11s  default-scheduler  Successfully assigned postgres-cluster/postgres-service-standby-0-0 to controlplane
  Normal  Pulled     4m11s  kubelet            spec.initContainers{fix-routing}: Container image "alpine:3.19" already present on machine and can be accessed by the pod
  Normal  Created    4m10s  kubelet            spec.initContainers{fix-routing}: Container created
  Normal  Started    4m10s  kubelet            spec.initContainers{fix-routing}: Container started
  Normal  Pulling    3m40s  kubelet            spec.containers{postgres}: Pulling image "timescale/timescaledb:latest-pg17"
  Normal  Pulled     3m14s  kubelet            spec.containers{postgres}: Successfully pulled image "timescale/timescaledb:latest-pg17" in 25.757s (25.757s including waiting). Image size: 458720692 bytes.
  Normal  Created    3m14s  kubelet            spec.containers{postgres}: Container created
  Normal  Started    3m14s  kubelet            spec.containers{postgres}: Container started
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n postgres-cluster postgres-service-standby-0-0 -- netstat -lntp
Defaulted container "postgres" out of: postgres, fix-routing (init)
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name    
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n postgres-cluster postgres-service-standby-0-0 -- ss -lntp
Defaulted container "postgres" out of: postgres, fix-routing (init)
error: Internal error occurred: Internal error occurred: error executing command in container: failed to exec in container: failed to start exec "2c06a66ef19f7253fa25fd290f8ba94a3d70ef63b8befa93aed8e04b138e5209": OCI runtime exec failed: exec failed: unable to start container process: exec: "ss": executable file not found in $PATH
root@controlplane:~/gitops-agnocon$ 
root@controlplane:~/gitops-agnocon$ 