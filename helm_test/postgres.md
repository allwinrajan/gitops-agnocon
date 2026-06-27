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