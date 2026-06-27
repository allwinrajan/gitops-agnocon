
Username for 'https://github.com': allwinrajan
Password for 'https://allwinrajan@github.com': 
remote: Enumerating objects: 348, done.
remote: Counting objects: 100% (348/348), done.
remote: Compressing objects: 100% (166/166), done.
remote: Total 348 (delta 166), reused 347 (delta 165), pack-reused 0 (from 0)
Receiving objects: 100% (348/348), 157.78 KiB | 9.86 MiB/s, done.
Resolving deltas: 100% (166/166), done.
root@controlplane:~$ cd gitops-agnocon/
root@controlplane:~/gitops-agnocon$ 
root@controlplane:~/gitops-agnocon$ 
root@controlplane:~/gitops-agnocon$ 
root@controlplane:~/gitops-agnocon$ kubectl apply -f gitops/bootstrap/namespaces.yaml
namespace/admin-app created
namespace/freeswitch created
namespace/influxdb created
namespace/kamailio created
namespace/multus-nad created
namespace/mysql-cluster created
namespace/nats created
namespace/observability created
namespace/postgres-cluster created
namespace/redis created
namespace/rtpengine created
namespace/rustfs created
namespace/watchdog created
root@controlplane:~/gitops-agnocon$ kubectl apply -f gitops/bootstrap/agnocon-project.yaml
appproject.argoproj.io/agnocon created
root@controlplane:~/gitops-agnocon$ kubectl apply -f gitops/applications/applicationset-production.yaml
applicationset.argoproj.io/agnocon-production created
root@controlplane:~/gitops-agnocon$ kubectl apply -f gitops/bootstrap/root-app.yaml
application.argoproj.io/agnocon-root created
root@controlplane:~/gitops-agnocon$ kubectl get pods -n mysql-cluster
NAME                          READY   STATUS     RESTARTS   AGE
mysql-service-primary-0       0/1     Init:0/1   0          26s
mysql-service-secondary-0-0   0/1     Init:0/1   0          26s
mysql-service-secondary-1-0   0/1     Init:0/1   0          26s
root@controlplane:~/gitops-agnocon$ kubectl get pods -n mysql-cluster
NAME                          READY   STATUS    RESTARTS   AGE
mysql-service-primary-0       1/1     Running   0          61s
mysql-service-secondary-0-0   1/1     Running   0          61s
mysql-service-secondary-1-0   1/1     Running   0          61s
root@controlplane:~/gitops-agnocon$ kubectl get pods -n mysql-cluster
NAME                          READY   STATUS    RESTARTS   AGE
mysql-service-primary-0       1/1     Running   0          73s
mysql-service-secondary-0-0   1/1     Running   0          73s
mysql-service-secondary-1-0   1/1     Running   0          73s
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n mysql-cluster mysql-service-primary-0 -- bash
Defaulted container "mysql" out of: mysql, fix-routing (init)
bash-4.4# mysql -uroot -p
Enter password: 
Welcome to the MySQL monitor.  Commands end with ; or \g.
Your MySQL connection id is 72
Server version: 8.0.36 MySQL Community Server - GPL

Copyright (c) 2000, 2024, Oracle and/or its affiliates.

Oracle is a registered trademark of Oracle Corporation and/or its
affiliates. Other names may be trademarks of their respective
owners.

Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

mysql> show databases;
+--------------------+
| Database           |
+--------------------+
| information_schema |
| mysql              |
| performance_schema |
| sys                |
+--------------------+
4 rows in set (0.01 sec)

mysql> exit
Bye
bash-4.4# exit
exit
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n mysql-cluster mysql-service-primary-0 -- bash
Defaulted container "mysql" out of: mysql, fix-routing (init)
bash-4.4# mysql -uroot -p
Enter password: 
Welcome to the MySQL monitor.  Commands end with ; or \g.
Your MySQL connection id is 105
Server version: 8.0.36 MySQL Community Server - GPL

Copyright (c) 2000, 2024, Oracle and/or its affiliates.

Oracle is a registered trademark of Oracle Corporation and/or its
affiliates. Other names may be trademarks of their respective
owners.

Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

mysql> CREATE DATABASE failover_test;
Query OK, 1 row affected (0.03 sec)

mysql> USE failover_test;
Database changed
mysql> 
mysql> CREATE TABLE demo (
    ->     id INT PRIMARY KEY,
    ->     name VARCHAR(100)
    -> );
Query OK, 0 rows affected (0.12 sec)

mysql> 
mysql> INSERT INTO demo VALUES (1,'Primary Working');
Query OK, 1 row affected (0.02 sec)

mysql> exit
Bye
bash-4.4# exit
exit
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n mysql-cluster mysql-service-secondary-0-0 -- bash
Defaulted container "mysql" out of: mysql, fix-routing (init)
bash-4.4# mysql -uroot -p
Enter password: 
Welcome to the MySQL monitor.  Commands end with ; or \g.
Your MySQL connection id is 14
Server version: 8.0.36 MySQL Community Server - GPL

Copyright (c) 2000, 2024, Oracle and/or its affiliates.

Oracle is a registered trademark of Oracle Corporation and/or its
affiliates. Other names may be trademarks of their respective
owners.

Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

mysql> SHOW DATABASES;
+--------------------+
| Database           |
+--------------------+
| information_schema |
| mysql              |
| performance_schema |
| sys                |
+--------------------+
4 rows in set (0.01 sec)

mysql> USE failover_test;
ERROR 1049 (42000): Unknown database 'failover_test'
mysql> SELECT * FROM demo;
ERROR 1046 (3D000): No database selected
mysql> 
mysql> SHOW REPLICA STATUS\G
Empty set (0.00 sec)

mysql> exit
Bye
bash-4.4# exit
exit
root@controlplane:~/gitops-agnocon$ kubectl get pods -n mysql-cluster -w
NAME                          READY   STATUS    RESTARTS   AGE
mysql-service-primary-0       1/1     Running   0          5m39s
mysql-service-secondary-0-0   1/1     Running   0          5m39s
mysql-service-secondary-1-0   1/1     Running   0          5m39s


# Expected

Great! Your MySQL cluster is up:

```text
mysql-service-primary-0       Running
mysql-service-secondary-0-0   Running
mysql-service-secondary-1-0   Running
```

Now let's verify **replication** and **failover**.

---

# Step 1: Check Services

```bash
kubectl get svc -n mysql-cluster
```

You'll likely see something like:

```text
mysql-service-primary
mysql-service-secondary
mysql-service-headless
```

---

# Step 2: Connect to the Primary

Execute a shell:

```bash
kubectl exec -it -n mysql-cluster mysql-service-primary-0 -- bash
```

Login:

```bash
mysql -uroot -p
```

or if you know the application user:

```bash
mysql -umyuser -p
```

---

# Step 3: Verify Primary

Inside MySQL:

```sql
SHOW DATABASES;
```

Create a test database:

```sql
CREATE DATABASE failover_test;
USE failover_test;

CREATE TABLE demo (
    id INT PRIMARY KEY,
    name VARCHAR(100)
);

INSERT INTO demo VALUES (1,'Primary Working');
```

Exit:

```sql
exit
```

---

# Step 4: Verify Replication on Secondary

Connect to a secondary:

```bash
kubectl exec -it -n mysql-cluster mysql-service-secondary-0-0 -- bash
```

Login:

```bash
mysql -uroot -p
```

Run:

```sql
SHOW DATABASES;

USE failover_test;

SELECT * FROM demo;
```

You should see:

```text
+----+-----------------+
| id | name            |
+----+-----------------+
| 1  | Primary Working |
+----+-----------------+
```

Repeat on the second replica if desired.

---

# Step 5: Check Replication Status

On a secondary:

```sql
SHOW REPLICA STATUS\G
```

(or on older versions, `SHOW SLAVE STATUS\G`)

Look for:

```text
Replica_IO_Running: Yes
Replica_SQL_Running: Yes
Seconds_Behind_Source: 0
```

---

# Step 6: Simulate Primary Failure

Delete the primary pod:

```bash
kubectl delete pod mysql-service-primary-0 -n mysql-cluster
```

Watch:

```bash
kubectl get pods -n mysql-cluster -w
```

Observe whether:

* A new `mysql-service-primary-0` pod is recreated.
* The secondaries continue running.

---

# Step 7: Test During Recovery

After the primary is recreated:

```bash
kubectl exec -it -n mysql-cluster mysql-service-primary-0 -- mysql -uroot -p
```

Run:

```sql
SELECT * FROM failover_test.demo;
```

Your data should still exist because it's stored on the persistent volume.

---

# Important: Is This Real Failover?

The answer depends on your Helm chart.

If your chart deploys:

```
Primary
├── Replica 1
└── Replica 2
```

and simply recreates the primary pod when it dies, **that is not automatic failover**. Kubernetes is just restarting the StatefulSet pod, and the same volume is reattached.

**Real automatic failover** means:

* Primary dies.
* One replica is promoted to become the new primary.
* The service endpoint switches to the promoted replica.
* Applications continue writing without manual intervention.

That requires components such as:

* MySQL Orchestrator
* MHA (Master High Availability)
* MySQL InnoDB Cluster
* MySQL Group Replication
* Percona Operator
* Bitnami MySQL with replication manager (depending on configuration)

---

## Let's verify what your chart supports

Run these commands and share the output:

```bash
kubectl get svc -n mysql-cluster

kubectl get statefulset -n mysql-cluster

kubectl get pods -n mysql-cluster -o wide

kubectl describe statefulset mysql-service-primary -n mysql-cluster

kubectl describe statefulset mysql-service-secondary-0 -n mysql-cluster
```

From that, I can tell you whether your deployment supports **true automatic failover** or only **pod recovery with replication**.
