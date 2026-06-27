root@controlplane:~/gitops-agnocon$ kubectl get pods -n redis -w
NAME                READY   STATUS     RESTARTS   AGE
redis-primary-0     0/1     Init:0/1   0          28s
redis-replica-1-0   0/1     Init:0/1   0          28s
redis-replica-2-0   0/1     Init:0/1   0          28s
redis-sentinel-0    0/1     Init:0/1   0          28s
redis-sentinel-1    0/1     Init:0/1   0          28s
redis-sentinel-2    0/1     Init:0/1   0          28s
redis-replica-1-0   0/1     PodInitializing   0          67s
redis-primary-0     0/1     PodInitializing   0          67s
redis-replica-2-0   0/1     PodInitializing   0          67s
redis-sentinel-2    0/1     PodInitializing   0          82s
redis-primary-0     1/1     Running           0          82s
redis-sentinel-1    0/1     PodInitializing   0          82s
redis-replica-2-0   1/1     Running           0          83s
redis-sentinel-1    1/1     Running           0          83s
redis-replica-1-0   1/1     Running           0          84s
redis-sentinel-2    1/1     Running           0          84s
redis-sentinel-0    0/1     PodInitializing   0          85s
redis-sentinel-0    1/1     Running           0          86s
^Croot@controlplane:~/gitops-agnocon$ kubectl get pods -n redis -w
NAME                READY   STATUS    RESTARTS   AGE
redis-primary-0     1/1     Running   0          93s
redis-replica-1-0   1/1     Running   0          93s
redis-replica-2-0   1/1     Running   0          93s
redis-sentinel-0    1/1     Running   0          93s
redis-sentinel-1    1/1     Running   0          93s
redis-sentinel-2    1/1     Running   0          93s

root@controlplane:~/gitops-agnocon$ kubectl exec -it -n redis redis-primary-0 -- bash
Defaulted container "redis" out of: redis, fix-routes (init)
root@redis-primary-0:/# redis-cli --user admin -a Admin@123
Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.
127.0.0.1:6379> 
127.0.0.1:6379> 
127.0.0.1:6379> 
127.0.0.1:6379> PING
PONG
127.0.0.1:6379> SET customer:1 "Allwin Rajan"
OK
127.0.0.1:6379> 
127.0.0.1:6379> SET customer:2 "DevOps"
OK
127.0.0.1:6379> 
127.0.0.1:6379> SET customer:3 "Kubernetes"
OK
127.0.0.1:6379> 
127.0.0.1:6379> HSET employee:1 name "John" role "SRE"
(integer) 2
127.0.0.1:6379> 
127.0.0.1:6379> LPUSH servers node01 node02 controlplane
(integer) 3
127.0.0.1:6379> 
127.0.0.1:6379> GET customer:1
"Allwin Rajan"
127.0.0.1:6379> 
127.0.0.1:6379> KEYS *
1) "servers"
2) "employee:1"
3) "customer:1"
4) "customer:2"
5) "customer:3"
127.0.0.1:6379> QUIT
root@redis-primary-0:/# exit
exit
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n redis redis-replica-1-0 -- bash
Defaulted container "redis" out of: redis, fix-routes (init)
root@redis-replica-1-0:/# redis-cli --user admin -a Admin@123
Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.
127.0.0.1:6379> INFO replication
# Replication
role:master
connected_slaves:0
master_failover_state:no-failover
master_replid:c290229c501d3d78a16e4eadb630fc1185b8030c
master_replid2:0000000000000000000000000000000000000000
master_repl_offset:0
second_repl_offset:-1
repl_backlog_active:0
repl_backlog_size:1048576
repl_backlog_first_byte_offset:0
repl_backlog_histlen:0
127.0.0.1:6379> GET customer:1
(nil)
127.0.0.1:6379> 
127.0.0.1:6379> HGETALL employee:1
(empty array)
127.0.0.1:6379> 
127.0.0.1:6379> LRANGE servers 0 -1
(empty array)
127.0.0.1:6379> exit
root@redis-replica-1-0:/# exit
exit
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n redis redis-sentinel-0 -- bash
Defaulted container "sentinel" out of: sentinel, wait-for-primary (init)
root@redis-sentinel-0:/# redis-cli -p 26379
127.0.0.1:26379> SENTINEL masters
1)  1) "name"
    2) "mymaster"
    3) "ip"
    4) "redis-primary-0.redis-headless.redis.svc.cluster.local"
    5) "port"
    6) "6379"
    7) "runid"
    8) "6bb4e85295884ac84f585b7592514876fe3340be"
    9) "flags"
   10) "master"
   11) "link-pending-commands"
   12) "0"
   13) "link-refcount"
   14) "1"
   15) "last-ping-sent"
   16) "0"
   17) "last-ok-ping-reply"
   18) "922"
   19) "last-ping-reply"
   20) "922"
   21) "down-after-milliseconds"
   22) "5000"
   23) "info-refresh"
   24) "1858"
   25) "role-reported"
   26) "master"
   27) "role-reported-time"
   28) "212645"
   29) "config-epoch"
   30) "0"
   31) "num-slaves"
   32) "0"
   33) "num-other-sentinels"
   34) "2"
   35) "quorum"
   36) "2"
   37) "failover-timeout"
   38) "10000"
   39) "parallel-syncs"
   40) "1"
127.0.0.1:26379> SENTINEL get-master-addr-by-name mymaster
1) "redis-primary-0.redis-headless.redis.svc.cluster.local"
2) "6379"
127.0.0.1:26379> exit
root@redis-sentinel-0:/# exit
exit
root@controlplane:~/gitops-agnocon$ kubectl delete pod redis-primary-0 -n redis
pod "redis-primary-0" deleted from redis namespace
root@controlplane:~/gitops-agnocon$ kubectl get pods -n redis -w
NAME                READY   STATUS     RESTARTS   AGE
redis-primary-0     0/1     Init:0/1   0          7s
redis-replica-1-0   1/1     Running    0          5m55s
redis-replica-2-0   1/1     Running    0          5m55s
redis-sentinel-0    1/1     Running    0          5m55s
redis-sentinel-1    1/1     Running    0          5m55s
redis-sentinel-2    1/1     Running    0          5m55s
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n redis redis-sentinel-0 -- redis-cli -p 26379
Defaulted container "sentinel" out of: sentinel, wait-for-primary (init)
127.0.0.1:26379> 
127.0.0.1:26379> SENTINEL get-master-addr-by-name mymaster
1) "redis-primary-0.redis-headless.redis.svc.cluster.local"
2) "6379"
127.0.0.1:26379> exit
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n redis redis-replica-1-0 -- redis-cli --user admin -a Admin@123
Defaulted container "redis" out of: redis, fix-routes (init)
Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.
127.0.0.1:6379> INFO replication
# Replication
role:master
connected_slaves:0
master_failover_state:no-failover
master_replid:c290229c501d3d78a16e4eadb630fc1185b8030c
master_replid2:0000000000000000000000000000000000000000
master_repl_offset:0
second_repl_offset:-1
repl_backlog_active:0
repl_backlog_size:1048576
repl_backlog_first_byte_offset:0
repl_backlog_histlen:0
127.0.0.1:6379> 
127.0.0.1:6379> exit
root@controlplane:~/gitops-agnocon$ kubectl exec -it -n redis redis-primary-0 -- redis-cli --user admin -a Admin@123
Defaulted container "redis" out of: redis, fix-routes (init)
Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.
127.0.0.1:6379> INFO replication
# Replication
role:master
connected_slaves:0
master_failover_state:no-failover
master_replid:5dab7144ff9ee4308c1f31a5d257056531da1f47
master_replid2:0000000000000000000000000000000000000000
master_repl_offset:0
second_repl_offset:-1
repl_backlog_active:0
repl_backlog_size:1048576
repl_backlog_first_byte_offset:0
repl_backlog_histlen:0
127.0.0.1:6379> 



# Expected

Excellent! Since all the Redis pods are running, you can now validate:

* ✅ Authentication
* ✅ Replication
* ✅ Sentinel monitoring
* ✅ Automatic failover
* ✅ Data persistence

---

# Step 1: Connect to the Primary

```bash
kubectl exec -it -n redis redis-primary-0 -- bash
```

Connect to Redis:

```bash
redis-cli --user admin -a Admin@123
```

Verify:

```redis
PING
```

Expected:

```text
PONG
```

---

# Step 2: Create Test Data

```redis
SET customer:1 "Allwin Rajan"

SET customer:2 "DevOps"

SET customer:3 "Kubernetes"

HSET employee:1 name "John" role "SRE"

LPUSH servers node01 node02 controlplane

GET customer:1

KEYS *
```

Expected:

```text
customer:1
customer:2
customer:3
employee:1
servers
```

Exit:

```redis
QUIT
```

---

# Step 3: Verify Replication

Connect to Replica 1

```bash
kubectl exec -it -n redis redis-replica-1-0 -- bash
```

```bash
redis-cli --user admin -a Admin@123
```

Check replication:

```redis
INFO replication
```

Expected:

```text
role:slave
master_host:...
master_link_status:up
```

Verify data:

```redis
GET customer:1

HGETALL employee:1

LRANGE servers 0 -1
```

Should return:

```text
Allwin Rajan

name
John

role
SRE

controlplane
node02
node01
```

Repeat on Replica 2.

---

# Step 4: Check Sentinel

Connect:

```bash
kubectl exec -it -n redis redis-sentinel-0 -- bash
```

Run:

```bash
redis-cli -p 26379
```

Now check:

```redis
SENTINEL masters
```

Expected:

```text
name
mymaster
```

Then

```redis
SENTINEL get-master-addr-by-name mymaster
```

Example:

```text
redis-primary
6379
```

Exit.

---

# Step 5: Simulate Failure

Delete the primary:

```bash
kubectl delete pod redis-primary-0 -n redis
```

Watch:

```bash
kubectl get pods -n redis -w
```

---

# Step 6: Observe Sentinel

While the primary is restarting:

```bash
kubectl exec -it -n redis redis-sentinel-0 -- redis-cli -p 26379
```

Run repeatedly:

```redis
SENTINEL get-master-addr-by-name mymaster
```

If automatic failover works, the returned master address should change to one of the replica pods.

---

# Step 7: Verify New Master

Connect to the new master:

```bash
kubectl exec -it -n redis redis-replica-1-0 -- redis-cli --user admin -a Admin@123
```

(or whichever pod Sentinel promoted)

Check:

```redis
INFO replication
```

Expected:

```text
role:master
```

Now write data:

```redis
SET failover success

GET failover
```

Expected:

```text
success
```

---

# Step 8: Verify Old Master

Once `redis-primary-0` is recreated:

```bash
kubectl exec -it -n redis redis-primary-0 -- redis-cli --user admin -a Admin@123
```

Run:

```redis
INFO replication
```

Expected:

```text
role:slave
```

Then:

```redis
GET failover
```

If replication has recovered correctly, you should see:

```text
success
```

---

# One-shot Validation Commands

### Primary

```bash
kubectl exec -it -n redis redis-primary-0 -- redis-cli --user admin -a Admin@123 INFO replication
```

### Replica 1

```bash
kubectl exec -it -n redis redis-replica-1-0 -- redis-cli --user admin -a Admin@123 INFO replication
```

### Replica 2

```bash
kubectl exec -it -n redis redis-replica-2-0 -- redis-cli --user admin -a Admin@123 INFO replication
```

### Sentinel

```bash
kubectl exec -it -n redis redis-sentinel-0 -- redis-cli -p 26379 SENTINEL masters
```

---

## What a successful HA test looks like

1. Write data to the primary.
2. Confirm both replicas can read the same data.
3. Delete `redis-primary-0`.
4. Sentinel elects one replica as the new master.
5. Writes to the new master succeed.
6. The recreated original primary rejoins as a replica.
7. All keys remain available throughout the process.
