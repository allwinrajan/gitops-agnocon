root@controlplane:~/gitops-agnocon$ kubectl get pods -n postgres-cluster -w
NAME                           READY   STATUS    RESTARTS   AGE
postgres-service-primary-0     1/1     Running   0          3m27s
postgres-service-standby-0-0   1/1     Running   0          3m27s
postgres-service-standby-1-0   1/1     Running   0          3m27s
^Croot@controlplane:~/gitops-agnoconkubectl exec -n postgres-cluster -it postgres-service-primary-0 -- psql -U postgres -c "SELECT pg_is_in_recovery();"
Defaulted container "postgres" out of: postgres, fix-routing (init)
 pg_is_in_recovery 
-------------------
 f
(1 row)

root@controlplane:~/gitops-agnocon$ kubectl exec -n postgres-cluster -it postgres-service-standby-0-0 -- psql -U postgres -c "SELECT pg_is_in_recovery();"
Defaulted container "postgres" out of: postgres, fix-routing (init)
 pg_is_in_recovery 
-------------------
 t
(1 row)

root@controlplane:~/gitops-agnocon$ kubectl exec -n postgres-cluster -it postgres-service-standby-1-0 -- psql -U postgres -c "SELECT pg_is_in_recovery();"
Defaulted container "postgres" out of: postgres, fix-routing (init)
 pg_is_in_recovery 
-------------------
 t
(1 row)

root@controlplane:~/gitops-agnocon$ kubectl exec -n postgres-cluster -it postgres-service-primary-0 -- psql -U postgres
Defaulted container "postgres" out of: postgres, fix-routing (init)
psql (17.10)
Type "help" for help.

postgres=# CREATE TABLE failover_test ( id SERIAL PRIMARY KEY, message TEXT ); INSERT INTO failover_test(message) VALUES ('Before Failover'); SELECT * FROM failover_test;
CREATE TABLE
INSERT 0 1
 id |     message     
----+-----------------
  1 | Before Failover
(1 row)

postgres=# EXIT
root@controlplane:~/gitops-agnocon$ kubectl delete pod postgres-service-primary-0 -n postgres-cluster
pod "postgres-service-primary-0" deleted from postgres-cluster namespace
root@controlplane:~/gitops-agnocon$ kubectl get pods -n postgres-cluster -w
NAME                           READY   STATUS     RESTARTS   AGE
postgres-service-primary-0     0/1     Init:0/1   0          6s
postgres-service-standby-0-0   1/1     Running    0          4m56s
postgres-service-standby-1-0   1/1     Running    0          4m56s
^Croot@controlplane:~/gitops-agnoconkubectl exec -n postgres-cluster -it postgres-service-primary-0 -- psql -U postgres -c "SELECT pg_is_in_recovery();"
Defaulted container "postgres" out of: postgres, fix-routing (init)
error: Internal error occurred: unable to upgrade connection: container not found ("postgres")
root@controlplane:~/gitops-agnocon$ kubectl exec -n postgres-cluster -it postgres-service-standby-0-0 -- psql -U postgres -c "SELECT pg_is_in_recovery();"
Defaulted container "postgres" out of: postgres, fix-routing (init)
 pg_is_in_recovery 
-------------------
 t
(1 row)

root@controlplane:~/gitops-agnocon$ kubectl exec -n postgres-cluster -it postgres-service-standby-1-0 -- psql -U postgres -c "SELECT pg_is_in_recovery();"
Defaulted container "postgres" out of: postgres, fix-routing (init)
 pg_is_in_recovery 
-------------------
 t
(1 row)

root@controlplane:~/gitops-agnocon$ kubectl get pods -n postgres-cluster -w
NAME                           READY   STATUS    RESTARTS   AGE
postgres-service-primary-0     0/1     Running   0          57s
postgres-service-standby-0-0   1/1     Running   0          5m47s
postgres-service-standby-1-0   1/1     Running   0          5m47s
root@controlplane:~/gitops-agnocon$ kubectl exec -n postgres-cluster -it postgres-service-primary-0 -- psql -U postgres
Defaulted container "postgres" out of: postgres, fix-routing (init)
psql (17.10)
Type "help" for help.

postgres=# SELECT * FROM failover_test;
 id |     message     
----+-----------------
  1 | Before Failover
(1 row)

postgres=# INSERT INTO failover_test(message) VALUES ('After Failover'); SELECT * FROM failover_test;
INSERT 0 1
 id |     message     
----+-----------------
  1 | Before Failover
  2 | After Failover
(2 rows)

postgres=# 
postgres=# 
postgres=# EXIT
root@controlplane:~/gitops-agnocon$ kubectl exec -n postgres-cluster -it postgres-service-standby-0-0 -- psql -U postgres -c "SELECT * FROM failover_test;"
Defaulted container "postgres" out of: postgres, fix-routing (init)
 id |     message     
----+-----------------
  1 | Before Failover
  2 | After Failover
(2 rows)

root@controlplane:~/gitops-agnocon$ 



ALL TEST PASSED